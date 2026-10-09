//! The host-level refusal vocabulary, kept in step with the macOS host.
//!
//! The daemon publishes its error codes and a test re-derives them. The host's
//! own codes had no such guard, which is how a second host ends up refusing with
//! a word the UI does not know. This closes that hole for the presence-selection
//! gate -- the piece of host state that caused today's `presence_selection_busy`
//! bug -- by reading the Swift constants and comparing.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use gmgn_windows_host::refusals::{
    HOST_ONLY_CODES, MIRRORED_AUTHORITY_CODES, host_refusal_codes, is_host_only, is_host_refusal,
};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("apps/windows-host 的上一级是仓库根")
        .to_path_buf()
}

/// The `static let codeX = "..."` constants in a Swift file.
///
/// The pattern is narrow on purpose: these declarations are the only place the
/// gate names its codes, and a loose "every snake_case string" scan would sweep
/// in log labels and settings keys that are not a vocabulary at all.
fn swift_code_constants(source: &str) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    for line in source.lines() {
        let line = line.trim();
        let Some(rest) = line.strip_prefix("static let code") else { continue };
        let Some((_, after)) = rest.split_once('=') else { continue };
        let after = after.trim();
        let Some(inner) = after.strip_prefix('"') else { continue };
        let Some(end) = inner.find('"') else { continue };
        out.insert(inner[..end].to_owned());
    }
    out
}

#[test]
fn the_host_refusal_vocabulary_covers_the_swift_gate_codes() {
    let gate = repo_root().join("apps/macos/UnityHost/UnityPresenceSelectionGate.swift");
    let source = std::fs::read_to_string(&gate)
        .unwrap_or_else(|e| panic!("read {}: {e}", gate.display()));

    let swift = swift_code_constants(&source);
    assert!(
        !swift.is_empty(),
        "no `static let code*` constants found in {}; the extraction or the Swift file changed",
        gate.display()
    );

    let missing: Vec<&String> = swift
        .iter()
        .filter(|code| !is_host_refusal(code))
        .collect();
    assert!(
        missing.is_empty(),
        "{} declares host refusal code(s) {missing:?} that the Windows host does not; \
         add them to `refusals`",
        gate.display()
    );

    println!(
        "swift gate declares {} code(s): {:?}\nwindows host declares {}: {:?}",
        swift.len(),
        swift,
        host_refusal_codes().count(),
        host_refusal_codes().collect::<Vec<_>>()
    );
}

/// The daemon's published codes, parsed out of its own `ERROR_CODES` list.
fn published_authority_codes() -> BTreeSet<String> {
    let contract = repo_root().join("services/gmgn-taskd/src/contract.rs");
    let source = std::fs::read_to_string(&contract)
        .unwrap_or_else(|e| panic!("read {}: {e}", contract.display()));
    let start = source
        .find("const ERROR_CODES: &[&str] = &[")
        .expect("contract.rs still declares ERROR_CODES");
    let end = source[start..]
        .find("];")
        .map(|i| start + i)
        .expect("the ERROR_CODES list must close");
    let codes: BTreeSet<String> = source[start..end]
        .split('"')
        .skip(1)
        .step_by(2)
        .map(str::to_owned)
        .collect();
    assert!(
        codes.len() > 100,
        "only {} published codes parsed; the extraction is wrong",
        codes.len()
    );
    codes
}

#[test]
fn every_host_code_is_either_mirrored_or_registered_as_host_only() {
    // This is the rule the first version of this test got wrong. It asserted the
    // two vocabularies were disjoint, and failed on `presence_renderer_pending`,
    // which the daemon publishes at `contract.rs:584`. The real invariant is a
    // partition, not disjointness: a code is either a faithful mirror of a
    // published authority code, or a listed host-only decision. Silence -- a code
    // that is neither -- is the failure.
    let published = published_authority_codes();

    for code in MIRRORED_AUTHORITY_CODES {
        assert!(
            published.contains(*code),
            "`{code}` is declared a mirror of an authority code, but the daemon does not \
             publish it; either the daemon renamed it or it belongs in HOST_ONLY_CODES"
        );
    }

    for code in HOST_ONLY_CODES {
        assert!(
            !published.contains(*code),
            "`{code}` is registered as host-only, but the daemon publishes it too; \
             a refusal with two possible authors is one the UI cannot explain"
        );
    }

    // And the two halves must not overlap each other.
    let mirrored: BTreeSet<&str> = MIRRORED_AUTHORITY_CODES.iter().copied().collect();
    let collisions: Vec<&&str> = HOST_ONLY_CODES
        .iter()
        .filter(|code| mirrored.contains(*code))
        .collect();
    assert!(
        collisions.is_empty(),
        "these codes are listed as both mirrored and host-only: {collisions:?}"
    );

    println!(
        "daemon publishes {} codes; the gate mirrors {} of them and adds {} host-only: {:?}",
        published.len(),
        MIRRORED_AUTHORITY_CODES.len(),
        HOST_ONLY_CODES.len(),
        HOST_ONLY_CODES
    );
}

#[test]
fn the_gate_fails_when_a_swift_code_is_not_registered() {
    // The red path, executed rather than assumed: pull a code out of the
    // vocabulary and show the same membership test the gate uses goes false.
    let every = repo_root().join("apps/macos/UnityHost/UnityPresenceSelectionGate.swift");
    let source = std::fs::read_to_string(&every)
        .unwrap_or_else(|e| panic!("read {}: {e}", every.display()));
    let swift = swift_code_constants(&source);
    assert!(!swift.is_empty());

    // Simulate "the Swift file gained a code nobody registered".
    let invented = "presence_selection_never_registered";
    assert!(
        !is_host_refusal(invented),
        "the invented code must not already be registered, or this demo proves nothing"
    );
    assert!(
        !swift.contains(invented),
        "the demo code must not collide with a real one"
    );
    // The gate's own predicate is what would fire.
    let unregistered: Vec<&str> = std::iter::once(invented)
        .chain(swift.iter().map(String::as_str))
        .filter(|code| !is_host_refusal(code))
        .collect();
    assert_eq!(
        unregistered,
        vec![invented],
        "expected exactly the invented code to be reported unregistered"
    );

    assert!(is_host_only("presence_selection_busy"));
    assert!(!is_host_only("presence_renderer_pending"));
}
