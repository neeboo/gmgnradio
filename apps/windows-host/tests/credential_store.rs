//! The credential-store rules, and the machine-checked link back to the macOS
//! ban this store is replacing.
//!
//! Three groups:
//!
//! 1. **The invariants `FileSpeechSecretStore` had**, reproduced and asserted
//!    (owner-only directory, owner-only file, atomic replace, size cap, no NUL,
//!    fixed name allowlist, symlink refusal, `clear` touching one secret only).
//! 2. **Where the root is**, on every platform, cross-checked against the
//!    literal path the macOS `MarbleAPIKeyProvider` uses.
//! 3. **The bans**: no keychain, no Windows Credential Manager, no credential
//!    read from the environment -- with the macOS ban list *read out of the
//!    macOS test itself* and asserted to be a subset of this one, so the two
//!    platforms cannot drift apart.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use gmgn_windows_host::credential::{
    ALLOWED_NAMES, CREDENTIAL_ENV_VARS, MAX_SECRET_BYTES, SecretStore, StoreError, default_root,
};

/// Every forbidden API, on both platforms.
///
/// Kept in the test rather than in `src/` on purpose: the ban scan reads every
/// `.rs` file under `src/`, and a list that lived there would find itself. The
/// macOS test has the same property by construction -- it lists the strings in
/// the test body and scans four *other* files.
const FORBIDDEN_CREDENTIAL_APIS: &[&str] = &[
    // The macOS keychain, verbatim from
    // `backgroundCredentialReadsCanNeverShowAKeychainPasswordPrompt`.
    "SecItemCopyMatching",
    "SecItemAdd",
    "SecItemUpdate",
    "SecItemDelete",
    "KeychainSpeechSecretStore(",
    "find-generic-password",
    "add-generic-password",
    // The Windows equivalent the user ruled out by name: the Credential
    // Manager, and DPAPI, which is the thing people reach for next.
    "CredReadW",
    "CredWriteW",
    "CredDeleteW",
    "CredEnumerateW",
    "CredReadA",
    "CredWriteA",
    "CryptProtectData",
    "CryptUnprotectData",
    "wincred",
];

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("apps/windows-host 的上一级是仓库根")
        .to_path_buf()
}

/// A directory that removes itself, so a failing assertion cannot leave state
/// behind for the next run.
struct TempRoot(PathBuf);

impl TempRoot {
    fn new(tag: &str) -> Self {
        let base = std::env::temp_dir().join(format!(
            "gmgn-winhost-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&base);
        Self(base)
    }
    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempRoot {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

// ------------------------------------------------------------- the invariants

#[test]
fn the_store_creates_a_private_directory() {
    let temp = TempRoot::new("dir");
    let store = SecretStore::with_root(temp.path());
    store.write("world-labs-api-key", "k").unwrap();

    let meta = std::fs::symlink_metadata(temp.path()).unwrap();
    assert!(meta.file_type().is_dir());

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        assert_eq!(
            meta.permissions().mode() & 0o777,
            0o700,
            "the secrets directory must be 0700, exactly like FileSpeechSecretStore's"
        );
    }
}

#[test]
fn the_store_writes_a_private_file() {
    let temp = TempRoot::new("file");
    let store = SecretStore::with_root(temp.path());
    store.write("world-labs-api-key", "secret-value").unwrap();

    assert_eq!(store.read("world-labs-api-key").as_deref(), Some("secret-value"));

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let meta = std::fs::symlink_metadata(temp.path().join("world-labs-api-key")).unwrap();
        assert_eq!(
            meta.permissions().mode() & 0o777,
            0o600,
            "the secret file must be 0600, exactly like FileSpeechSecretStore's"
        );
    }
}

#[test]
fn the_store_refuses_names_outside_the_allowlist() {
    let temp = TempRoot::new("allow");
    let store = SecretStore::with_root(temp.path());

    for name in ["../../etc/passwd", "world-labs-api-key/../x", "", "something-else"] {
        assert_eq!(
            store.write(name, "v"),
            Err(StoreError::NameNotAllowed(name.to_owned())),
            "`{name}` must be refused before it reaches the filesystem"
        );
    }

    // The allowed set is exactly the two macOS stores' file names.
    assert!(ALLOWED_NAMES.contains(&"world-labs-api-key"));
    for provider in ["bailian", "elevenlabs", "fish"] {
        assert!(ALLOWED_NAMES.contains(&format!("speech-{provider}.key").as_str()));
        assert!(ALLOWED_NAMES.contains(&format!("speech-{provider}.imported").as_str()));
    }
}

#[test]
fn the_store_refuses_oversized_and_binary_values() {
    let temp = TempRoot::new("size");
    let store = SecretStore::with_root(temp.path());

    assert_eq!(store.write("world-labs-api-key", ""), Err(StoreError::ValueRejected));
    assert_eq!(
        store.write("world-labs-api-key", "a\0b"),
        Err(StoreError::ValueRejected),
        "a NUL must be refused, like FileSpeechSecretStore's `!value.contains(\"\\0\")`"
    );
    let too_long = "a".repeat(MAX_SECRET_BYTES + 1);
    assert_eq!(
        store.write("world-labs-api-key", &too_long),
        Err(StoreError::ValueRejected)
    );
    // Exactly at the cap is fine -- the cap is a cap, not an off-by-one.
    let at_cap = "a".repeat(MAX_SECRET_BYTES);
    assert!(store.write("world-labs-api-key", &at_cap).is_ok());
    assert_eq!(store.read("world-labs-api-key").map(|v| v.len()), Some(MAX_SECRET_BYTES));
}

#[test]
fn the_store_replaces_without_leaving_a_temporary_behind() {
    let temp = TempRoot::new("atomic");
    let store = SecretStore::with_root(temp.path());

    store.write("world-labs-api-key", "first").unwrap();
    store.write("world-labs-api-key", "second").unwrap();
    assert_eq!(store.read("world-labs-api-key").as_deref(), Some("second"));

    let leftovers: Vec<String> = std::fs::read_dir(temp.path())
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with(".tmp-"))
        .collect();
    assert!(
        leftovers.is_empty(),
        "the temp+rename write must not leave staging files behind, found {leftovers:?}"
    );
}

#[test]
fn the_store_reads_are_bounded_and_ignore_non_files() {
    let temp = TempRoot::new("bounded");
    let store = SecretStore::with_root(temp.path());
    store.ensure_root().unwrap();

    // An oversized file on disk must not be read back: the cap is enforced on
    // read as well as on write, because the file can be edited by hand.
    std::fs::write(
        temp.path().join("world-labs-api-key"),
        "a".repeat(MAX_SECRET_BYTES + 1),
    )
    .unwrap();
    assert_eq!(store.read("world-labs-api-key"), None);
    assert!(!store.is_configured("world-labs-api-key"));

    // A directory where a secret should be is not a secret.
    std::fs::remove_file(temp.path().join("world-labs-api-key")).unwrap();
    std::fs::create_dir(temp.path().join("world-labs-api-key")).unwrap();
    assert_eq!(store.read("world-labs-api-key"), None);

    // Whitespace-only counts as unconfigured, matching
    // `MarbleAPIKeySettingsModel.isConfigured`'s non-empty test on trimmed text.
    std::fs::remove_dir(temp.path().join("world-labs-api-key")).unwrap();
    store.write("world-labs-api-key", "   ").unwrap();
    assert!(!store.is_configured("world-labs-api-key"));
}

#[test]
fn the_store_clears_one_secret_and_leaves_the_others() {
    let temp = TempRoot::new("clear");
    let store = SecretStore::with_root(temp.path());

    store.write("world-labs-api-key", "marble").unwrap();
    store.write("speech-elevenlabs.key", "eleven").unwrap();

    store.clear("world-labs-api-key").unwrap();
    assert_eq!(store.read("world-labs-api-key"), None);
    assert_eq!(
        store.read("speech-elevenlabs.key").as_deref(),
        Some("eleven"),
        "clearing one provider's key must not take another's"
    );
    // Clearing twice is not an error: `marble.clear()` is idempotent.
    assert!(store.clear("world-labs-api-key").is_ok());
}

#[cfg(unix)]
#[test]
fn the_store_refuses_a_symlinked_root() {
    let temp = TempRoot::new("symlink");
    let real = temp.path().join("real");
    std::fs::create_dir_all(&real).unwrap();
    let link = temp.path().join("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();

    let store = SecretStore::with_root(&link);
    assert_eq!(
        store.write("world-labs-api-key", "v"),
        Err(StoreError::RootNotAPrivateDirectory),
        "a symlinked secrets root could be pointing anywhere"
    );
}

#[cfg(unix)]
#[test]
fn the_store_refuses_a_symlinked_secret_file() {
    let temp = TempRoot::new("symlink-file");
    let store = SecretStore::with_root(temp.path());
    store.ensure_root().unwrap();

    let target = temp.path().join("elsewhere");
    std::fs::write(&target, "not-a-secret").unwrap();
    std::os::unix::fs::symlink(&target, temp.path().join("world-labs-api-key")).unwrap();

    assert_eq!(
        store.write("world-labs-api-key", "v"),
        Err(StoreError::RootNotAPrivateDirectory),
        "writing through a symlink is a redirect, not a save"
    );
}

// ---------------------------------------------------------------- the location

#[test]
fn the_root_sits_under_the_platform_user_private_directory() {
    let root = default_root().expect("a user config directory must resolve");

    // The last two components are the same on every platform; only the base
    // differs, and that is the one intentional difference.
    assert!(
        root.ends_with(Path::new("ai.gmgn.radio").join("secrets")),
        "expected the root to end with `ai.gmgn.radio/secrets`, got {}",
        root.display()
    );

    #[cfg(target_os = "macos")]
    {
        let home = std::env::var("HOME").unwrap();
        assert_eq!(
            root,
            PathBuf::from(home)
                .join("Library")
                .join("Application Support")
                .join("ai.gmgn.radio")
                .join("secrets")
        );
    }

    #[cfg(windows)]
    {
        let local = std::env::var("LOCALAPPDATA").expect("%LOCALAPPDATA% must exist on Windows");
        assert!(
            root.starts_with(&local),
            "the secrets root must be inside %LOCALAPPDATA% (per-user, non-roaming), got {}",
            root.display()
        );
        let roaming = std::env::var("APPDATA").unwrap_or_default();
        if !roaming.is_empty() {
            assert!(
                !root.starts_with(&roaming),
                "the secrets root must NOT be in the roaming profile"
            );
        }
    }
}

#[test]
fn the_root_and_the_marble_file_name_match_the_macos_host() {
    // Read the macOS source, so this is a real cross-check and not a restatement.
    let client = repo_root().join("apps/macos/Sources/GMGNRadio/VisualEngine/MarbleWorldClient.swift");
    let source = std::fs::read_to_string(&client)
        .unwrap_or_else(|e| panic!("read {}: {e}", client.display()));

    assert!(
        source.contains("\"ai.gmgn.radio/secrets\""),
        "MarbleWorldClient.swift no longer builds its secrets path from `ai.gmgn.radio/secrets`; \
         the Rust root above must be revisited"
    );
    assert!(
        source.contains("\"world-labs-api-key\""),
        "MarbleWorldClient.swift no longer names the key `world-labs-api-key`; \
         `MARBLE_KEY_NAME` must follow it"
    );
    assert!(ALLOWED_NAMES.contains(&"world-labs-api-key"));

    // And the speech store's provider allowlist.
    let speech = repo_root()
        .join("apps/macos/Sources/GMGNRadio/Presence/ProductSpeechSecretStore.swift");
    let speech_source =
        std::fs::read_to_string(&speech).unwrap_or_else(|e| panic!("read {}: {e}", speech.display()));
    assert!(
        speech_source.contains(r#"["bailian", "elevenlabs", "fish"]"#),
        "ProductSpeechSecretStore's provider allowlist changed; ALLOWED_NAMES must follow it"
    );
}

// -------------------------------------------------------------------- the bans

/// Every `.rs` file under `src/`, which is what the ban scan reads.
fn crate_sources() -> Vec<(PathBuf, String)> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut out = Vec::new();
    let mut stack = vec![root];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().and_then(|e| e.to_str()) == Some("rs") {
                let text = std::fs::read_to_string(&path)
                    .unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
                out.push((path, text));
            }
        }
    }
    assert!(!out.is_empty(), "no sources found to scan");
    out
}

#[test]
fn no_keychain_or_credential_manager_api_is_used_anywhere_in_this_crate() {
    // Comments are stripped first, and that is the point of the test rather than
    // a loophole in it. The rule being enforced is "this code does not call a
    // credential service"; the module doc in `src/credential.rs` names
    // `SecItemAdd` and friends precisely in order to explain why they are not
    // called, and a scan that punished that would quietly delete the
    // explanation. String literals are kept, which is where a real violation
    // would live -- shelling out to `security find-generic-password` is a string
    // literal, not a comment.
    let mut hits = Vec::new();
    for (path, text) in crate_sources() {
        let code = gmgn_windows_host::contract::strip_rust_comments(&text);
        for forbidden in FORBIDDEN_CREDENTIAL_APIS {
            if code.contains(forbidden) {
                hits.push(format!("{}: `{forbidden}`", path.display()));
            }
        }
    }
    assert!(
        hits.is_empty(),
        "this crate must not reach a credential service:\n  - {}",
        hits.join("\n  - ")
    );
}

#[test]
fn the_ban_scan_would_actually_catch_a_violation() {
    // The ban scan is only worth having if it fires. This is the same check,
    // run against a synthetically "violating" source, so the red path is
    // executed on every test run rather than assumed.
    let planted = r#"
        fn steal() -> String {
            let out = std::process::Command::new("security")
                .args(["find-generic-password", "-s", "gmgn"])
                .output();
            String::from_utf8_lossy(&out.unwrap().stdout).into_owned()
        }
    "#;
    let code = gmgn_windows_host::contract::strip_rust_comments(planted);
    assert!(
        code.contains("find-generic-password"),
        "the scan must still see a banned verb inside a string literal"
    );

    // And a comment naming the same thing must NOT fire, which is what keeps the
    // documentation in `src/credential.rs` writable.
    let prose = "// we deliberately never call SecItemAdd or CredReadW here\n";
    let code = gmgn_windows_host::contract::strip_rust_comments(prose);
    assert!(
        !code.contains("SecItemAdd") && !code.contains("CredReadW"),
        "prose that names a banned API is not a violation"
    );
}

#[test]
fn the_macos_ban_is_a_subset_of_this_one() {
    // Read the macOS ban out of the macOS test. If someone adds a keychain API
    // there, this fails until the Windows ban covers it too.
    let test = repo_root().join("apps/macos/Tests/GMGNRadioTests/AppSmokeTests.swift");
    let source = std::fs::read_to_string(&test)
        .unwrap_or_else(|e| panic!("read {}: {e}", test.display()));

    let start = source
        .find("for forbidden in [")
        .expect("AppSmokeTests still lists forbidden credential APIs");
    let rest = &source[start + "for forbidden in [".len()..];
    let end = rest.find(']').expect("the forbidden list must close");
    let macos_banned: BTreeSet<String> = rest[..end]
        .split(',')
        .map(|piece| piece.trim().trim_matches('"').to_owned())
        .filter(|piece| !piece.is_empty())
        .collect();

    assert!(
        !macos_banned.is_empty(),
        "parsed an empty macOS ban list; the extraction above is wrong"
    );
    let mine: BTreeSet<&str> = FORBIDDEN_CREDENTIAL_APIS.iter().copied().collect();
    let missing: Vec<&str> = macos_banned
        .iter()
        .map(String::as_str)
        .filter(|api| !mine.contains(api))
        .collect();
    assert!(
        missing.is_empty(),
        "the macOS keychain ban covers {missing:?}, which the Windows ban does not; \
         add them to FORBIDDEN_CREDENTIAL_APIS"
    );
}

#[test]
fn no_credential_is_read_from_the_environment() {
    let mut hits = Vec::new();
    for (path, text) in crate_sources() {
        for var in CREDENTIAL_ENV_VARS {
            // A `std::env::var("..._API_KEY")` read would be the failure.
            if text.contains(&format!("env::var(\"{var}\")"))
                || text.contains(&format!("var_os(\"{var}\")"))
            {
                hits.push(format!("{}: reads `{var}`", path.display()));
            }
        }
    }
    assert!(
        hits.is_empty(),
        "credentials must come from the private store, never the environment \
         (which every child process inherits):\n  - {}",
        hits.join("\n  - ")
    );
}
