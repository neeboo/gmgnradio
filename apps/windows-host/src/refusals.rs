//! The **host-level refusal codes**: the vocabulary a host raises around the
//! presence-selection gate.
//!
//! ## Why this list exists at all
//!
//! `services/gmgn-taskd/src/contract.rs` publishes 779 error codes, and a test
//! there re-derives that list from the authority's own sources, so the
//! authority's half is covered. The host's half was not. A second host that
//! invents its own word here -- `busy`, `selection_locked`, anything -- produces
//! a UI that cannot explain the refusal to the user, and the failure is invisible
//! until someone clicks during a slow load. That is precisely today's bug: a
//! manual selection was answered `presence_selection_busy` while the only thing
//! running was a *read*, and the click was discarded.
//!
//! ## The vocabulary is mixed, and that is the interesting part
//!
//! Reading `apps/macos/UnityHost/UnityPresenceSelectionGate.swift:71-73` and
//! then checking each code against the daemon's publisher
//! (`services/gmgn-taskd/src/contract.rs:584`) splits the three in two:
//!
//! | code | author |
//! |---|---|
//! | `presence_selection_busy` | **host only** -- the daemon never sends it |
//! | `presence_renderer_pending` | **daemon publishes it**; the host mirrors it |
//! | `presence_selection_stale_cleared` | **host only**, diagnostic (log, not refusal) |
//!
//! This was not obvious and was found by a test rather than by reading: the
//! first version of `tests/host_refusals.rs` asserted the two sets were disjoint,
//! and it failed on `presence_renderer_pending`. The correct rule is the one the
//! repository already uses for ops (`op_coverage.rs::UNITY_HOST_ONLY_OPS`): a
//! code must be *either* a faithful mirror of a published authority code *or*
//! registered here as host-only. Silence is the only wrong answer.
//!
//! So a host-only code is a deliberate, listed decision, and the test fails when
//! the daemon starts publishing a code this host was treating as its own (or
//! vice versa) -- two authors for one refusal is a UI that cannot say who refused.

/// Codes the daemon publishes and this host only mirrors.
///
/// Nothing here is invented by the host; if the daemon renames one, the host
/// follows or the test fails.
pub const MIRRORED_AUTHORITY_CODES: &[&str] = &[
    // `services/gmgn-taskd/src/contract.rs:584`.
    "presence_renderer_pending",
    // `services/gmgn-taskd/src/contract.rs:585`. The gate names the stale
    // renderer receipt separately; the daemon's spelling is the one on the wire.
    "presence_renderer_receipt_stale",
];

/// Codes only a host raises, with the reason each is not the daemon's business.
pub const HOST_ONLY_CODES: &[&str] = &[
    // Raised on the strength of a marker only the host holds. It is a
    // *non-destructive* refusal: the UI shows which operation holds the gate and
    // since when, rather than discarding the click.
    "presence_selection_busy",
    // Diagnostic: a marker outlived its own deadline and a later selection
    // reclaimed it. Logged, never shown as a failure. Kept in this list because a
    // second host that drops it from its logs loses the only evidence that a
    // marker ever hung.
    "presence_selection_stale_cleared",
    // Host-only. `UnityPresenceSettingsBridge.awaitSelectionPreparation` waited
    // for the *host's own* preparation (`prepareManualMotionSelection`'s
    // `presence.motion.stop`) instead of letting that freshly-begun marker refuse
    // the selection it was preparing. The marker never leaves the host, so the
    // daemon never publishes this code; the Swift declaration is
    // `UnityPresenceSelectionGate.swift:112` (`codePreparationWaited`).
    "presence_selection_preparation_waited",
];

/// Every code that belongs to the gate's vocabulary.
pub fn host_refusal_codes() -> impl Iterator<Item = &'static str> {
    MIRRORED_AUTHORITY_CODES.iter().chain(HOST_ONLY_CODES).copied()
}

/// Whether `code` is part of the gate's vocabulary.
pub fn is_host_refusal(code: &str) -> bool {
    host_refusal_codes().any(|candidate| candidate == code)
}

/// Whether `code` is one this host raises without the authority.
pub fn is_host_only(code: &str) -> bool {
    HOST_ONLY_CODES.contains(&code)
}
