//! User-private credential storage, portable, **no keychain and no Credential
//! Manager**.
//!
//! ## Why there is no OS secret service in here
//!
//! The repository already decided this on macOS and enforces it with a test:
//! `backgroundCredentialReadsCanNeverShowAKeychainPasswordPrompt`
//! (`apps/macos/Tests/GMGNRadioTests/AppSmokeTests.swift:28`) scans
//! `KeychainMusicProviderSessionStore.swift`, `AgentSettingsModel.swift`,
//! `ProductSpeechSecretStore.swift` and `UnityProductSettings.swift` for
//! `SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate`, `SecItemDelete`,
//! `KeychainSpeechSecretStore(`, `find-generic-password` and
//! `add-generic-password`, and fails if any appears. The reason is in the test's
//! name: a keychain read from a background process can raise an interactive
//! password prompt, which is a hang the user cannot see.
//!
//! So credentials are **private files** in the user's own config directory. The
//! same rule is carried to Windows here rather than being translated into the
//! Windows equivalent (`Credential Manager`, `CredRead`/`CredWrite`): the user's
//! instruction is to keep credentials in user-private configuration, not in a
//! credential service. `tests/credential_store.rs` re-runs the macOS test's
//! scan against *this* crate's own source, so the ban is enforced on the Windows
//! side too.
//!
//! ## What is reproduced from `FileSpeechSecretStore`
//!
//! `apps/macos/Sources/GMGNRadio/Presence/ProductSpeechSecretStore.swift` is the
//! shape being moved. Its invariants are reproduced one for one, because each
//! one is load-bearing:
//!
//! | invariant | why | here |
//! |---|---|---|
//! | directory `0700` | nobody else may list the secrets | [`SecretStore::ensure_root`] |
//! | file `0600` | nobody else may read a key | [`SecretStore::write`] |
//! | write to a temp name, then `rename` | a reader never sees a half-written key | [`SecretStore::write`] |
//! | `lstat` says "regular file", not a symlink | a symlink is someone redirecting the write | [`SecretStore::read`] |
//! | value `<= 8192` bytes, no NUL | a size cap and a binary guard | [`SecretStore::write`] |
//! | a fixed provider allowlist | the name is not attacker-controlled | [`SecretStore::path`] |
//! | `clear` removes the file, not the directory | clearing one key must not take the others | [`SecretStore::clear`] |
//!
//! ## Where it lives per platform
//!
//! | platform | root |
//! |---|---|
//! | macOS | `~/Library/Application Support/ai.gmgn.radio/secrets` |
//! | Windows | `%LOCALAPPDATA%\ai.gmgn.radio\secrets` |
//! | other unix | `$XDG_CONFIG_HOME/ai.gmgn.radio/secrets` (else `~/.config/...`) |
//!
//! `GMGN_SECRETS_DIR` overrides all three, which is what makes the tests
//! hermetic and mirrors the `E2ERuntime` overrides the macOS side already has.
//!
//! `%LOCALAPPDATA%` and not `%APPDATA%`: `%APPDATA%` is the *roaming* profile and
//! syncs to a domain server, which is the last place a provider key should go.
//! `%LOCALAPPDATA%` is per-machine, per-user, and Windows creates it with an
//! inherited ACL that grants the user (and SYSTEM/Administrators) and nobody
//! else. [`crate::windows_acl`] additionally replaces that inherited ACL with an
//! explicit owner-only one, because "the default is probably fine" is not a
//! security argument.

use std::fmt;
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// The largest value this store will accept or return, matching
/// `FileSpeechSecretStore`'s own cap.
pub const MAX_SECRET_BYTES: usize = 8192;

/// The only names that may be written.
///
/// Borrowed verbatim from the two macOS stores being replaced:
/// `FileSpeechSecretStore.path` allows `bailian`, `elevenlabs`, `fish`, and
/// `MarbleAPIKeyProvider.defaultFileURL` is
/// `.../secrets/world-labs-api-key`.
pub const ALLOWED_NAMES: &[&str] = &[
    "world-labs-api-key",
    "speech-bailian.key",
    "speech-elevenlabs.key",
    "speech-fish.key",
    "speech-bailian.imported",
    "speech-elevenlabs.imported",
    "speech-fish.imported",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StoreError {
    /// The name is not in [`ALLOWED_NAMES`].
    NameNotAllowed(String),
    /// No platform user-config directory could be resolved.
    NoUserConfigDirectory,
    /// The value is too long or contains a NUL.
    ValueRejected,
    /// The root exists but is not a directory, or is a symlink.
    RootNotAPrivateDirectory,
    /// An OS call failed. The string is the operation, not a payload.
    Io(&'static str),
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NameNotAllowed(name) => {
                write!(f, "`{name}` is not an allowed secret name")
            }
            Self::NoUserConfigDirectory => write!(f, "no user config directory could be resolved"),
            Self::ValueRejected => {
                write!(f, "secret must be non-empty, <= {MAX_SECRET_BYTES} bytes, and free of NUL")
            }
            Self::RootNotAPrivateDirectory => {
                write!(f, "the secrets root is not a real directory (symlink or file?)")
            }
            Self::Io(op) => write!(f, "{op} failed"),
        }
    }
}

impl std::error::Error for StoreError {}

/// The user-private secrets directory.
#[derive(Debug, Clone)]
pub struct SecretStore {
    root: PathBuf,
}

impl SecretStore {
    /// The root for this platform, honouring `GMGN_SECRETS_DIR`.
    pub fn for_user() -> Result<Self, StoreError> {
        Ok(Self { root: default_root()? })
    }

    /// A store rooted anywhere. Tests use this; production uses
    /// [`SecretStore::for_user`].
    pub fn with_root(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Resolve an allowed name to a path inside the root.
    ///
    /// The allowlist is checked **before** the name touches the filesystem, so
    /// `../../etc/passwd` cannot even be expressed.
    pub fn path(&self, name: &str) -> Result<PathBuf, StoreError> {
        if !ALLOWED_NAMES.contains(&name) {
            return Err(StoreError::NameNotAllowed(name.to_owned()));
        }
        Ok(self.root.join(name))
    }

    /// Create the root if missing and force it owner-only.
    ///
    /// Refuses a root that exists as anything but a real directory: a symlink
    /// here would silently move every subsequent write somewhere else.
    pub fn ensure_root(&self) -> Result<(), StoreError> {
        match fs::symlink_metadata(&self.root) {
            Ok(meta) if meta.file_type().is_dir() => {}
            Ok(_) => return Err(StoreError::RootNotAPrivateDirectory),
            Err(_) => {
                fs::create_dir_all(&self.root).map_err(|_| StoreError::Io("create_dir_all"))?;
                let meta =
                    fs::symlink_metadata(&self.root).map_err(|_| StoreError::Io("symlink_metadata"))?;
                if !meta.file_type().is_dir() {
                    return Err(StoreError::RootNotAPrivateDirectory);
                }
            }
        }
        restrict_root(&self.root)?;
        Ok(())
    }

    /// Write a secret atomically, owner-only.
    pub fn write(&self, name: &str, value: &str) -> Result<(), StoreError> {
        let file = self.path(name)?;
        if value.is_empty()
            || value.len() > MAX_SECRET_BYTES
            || value.as_bytes().contains(&0)
        {
            return Err(StoreError::ValueRejected);
        }
        self.ensure_root()?;

        // Refuse to write through an existing symlink: `rename` would replace
        // the link itself on unix, but the check documents the intent and stops
        // the Windows path (where the link is followed) from diverging.
        if let Ok(meta) = fs::symlink_metadata(&file)
            && !meta.file_type().is_file()
        {
            return Err(StoreError::RootNotAPrivateDirectory);
        }

        let temporary = self.root.join(format!(".tmp-{}", unique_suffix()));
        {
            let mut handle = create_owner_only(&temporary)?;
            handle.write_all(value.as_bytes()).map_err(|_| StoreError::Io("write"))?;
            handle.sync_all().map_err(|_| StoreError::Io("sync_all"))?;
        }
        match fs::rename(&temporary, &file) {
            Ok(()) => Ok(()),
            Err(_) => {
                let _ = fs::remove_file(&temporary);
                Err(StoreError::Io("rename"))
            }
        }
    }

    /// Read a secret, or `None` if it is absent, not a regular file, or over the
    /// cap.
    pub fn read(&self, name: &str) -> Option<String> {
        let file = self.path(name).ok()?;
        let meta = fs::symlink_metadata(&file).ok()?;
        if !meta.file_type().is_file() || meta.len() > MAX_SECRET_BYTES as u64 {
            return None;
        }
        String::from_utf8(fs::read(&file).ok()?).ok()
    }

    /// Remove just this secret. The directory stays, so clearing one provider
    /// cannot take another's key with it.
    pub fn clear(&self, name: &str) -> Result<(), StoreError> {
        let file = self.path(name)?;
        match fs::remove_file(&file) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(_) => Err(StoreError::Io("remove_file")),
        }
    }

    /// Whether a usable secret exists. Mirrors
    /// `MarbleAPIKeySettingsModel.isConfigured`, which is "the file is there and
    /// non-empty" -- *not* "the key is valid", which only the provider can say.
    pub fn is_configured(&self, name: &str) -> bool {
        self.read(name).is_some_and(|v| !v.trim().is_empty())
    }
}

fn unique_suffix() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{}-{now}-{n}", std::process::id())
}

#[cfg(unix)]
fn create_owner_only(path: &Path) -> Result<fs::File, StoreError> {
    use std::os::unix::fs::OpenOptionsExt as _;
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|_| StoreError::Io("open"))
}

#[cfg(not(unix))]
fn create_owner_only(path: &Path) -> Result<fs::File, StoreError> {
    // Windows has no mode bits; the ACL is what protects the file, and it is
    // inherited from a root that `windows_acl::restrict_to_current_user` has
    // already replaced.
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|_| StoreError::Io("open"))
}

#[cfg(unix)]
fn restrict_root(root: &Path) -> Result<(), StoreError> {
    use std::os::unix::fs::PermissionsExt as _;
    fs::set_permissions(root, fs::Permissions::from_mode(0o700))
        .map_err(|_| StoreError::Io("set_permissions(0700)"))
}

#[cfg(windows)]
fn restrict_root(root: &Path) -> Result<(), StoreError> {
    crate::windows_acl::restrict_to_current_user(root)
}

#[cfg(not(any(unix, windows)))]
fn restrict_root(_root: &Path) -> Result<(), StoreError> {
    Ok(())
}

/// The per-platform user-private root.
pub fn default_root() -> Result<PathBuf, StoreError> {
    if let Some(dir) = std::env::var_os("GMGN_SECRETS_DIR") {
        return Ok(PathBuf::from(dir));
    }
    Ok(user_config_base()?.join("ai.gmgn.radio").join("secrets"))
}

#[cfg(target_os = "macos")]
fn user_config_base() -> Result<PathBuf, StoreError> {
    let home = std::env::var_os("HOME").ok_or(StoreError::NoUserConfigDirectory)?;
    Ok(PathBuf::from(home).join("Library").join("Application Support"))
}

#[cfg(windows)]
fn user_config_base() -> Result<PathBuf, StoreError> {
    // `%LOCALAPPDATA%`, deliberately not `%APPDATA%`: the roaming profile syncs
    // to a domain server, and a provider key must not travel with it.
    std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .ok_or(StoreError::NoUserConfigDirectory)
}

#[cfg(all(unix, not(target_os = "macos")))]
fn user_config_base() -> Result<PathBuf, StoreError> {
    if let Some(xdg) = std::env::var_os("XDG_CONFIG_HOME") {
        return Ok(PathBuf::from(xdg));
    }
    let home = std::env::var_os("HOME").ok_or(StoreError::NoUserConfigDirectory)?;
    Ok(PathBuf::from(home).join(".config"))
}

#[cfg(not(any(unix, windows)))]
fn user_config_base() -> Result<PathBuf, StoreError> {
    Err(StoreError::NoUserConfigDirectory)
}

/// Environment variables that name a credential.
///
/// Listed so that `tests/credential_store.rs` can assert this crate never reads
/// one: the environment is inherited by every child process, so a key that
/// arrives that way is a key handed to whatever the resident agent spawns. The
/// store's own `GMGN_SECRETS_DIR` override is a *directory*, not a secret, and
/// is deliberately not on this list.
pub const CREDENTIAL_ENV_VARS: &[&str] = &[
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "ELEVENLABS_API_KEY",
    "BAILIAN_API_KEY",
    "MARBLE_API_KEY",
    "WORLD_LABS_API_KEY",
];
