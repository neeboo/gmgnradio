//! The second host's registration of the op contract.
//!
//! **Generated from the contract, then hand-frozen.** The op names and their
//! declared field sets below are exactly the `OPS` table in
//! `apps/gpui-ui/tests/interface_parity.rs` as of this commit; they were emitted
//! by reading that table, not by retyping it. `tests/second_host_contract.rs`
//! re-reads the table at test time and fails in **both** directions, so this file
//! cannot drift:
//!
//! * a new op in the UI with no registration here -> red;
//! * a registration here for an op the UI no longer emits -> red;
//! * a registration that drops a field the UI sends -> red;
//! * a `Status::Implemented` with no handler under `src/handlers/` -> red.
//!
//! `reads` is the **specification** (what this host promises to read). `status`
//! is the **progress** (what it can do today). Keeping them separate means the
//! migration ledger is machine-readable instead of a paragraph in a doc.

use crate::handlers::IMPLEMENTED_OPS;

/// What this host is able to do for one op.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    /// A handler exists under `src/handlers/` and the gate proves it by finding
    /// the op literal in that tree.
    Implemented,
    /// Registered, specified, and deliberately not built yet. The reason is the
    /// migration note and is surfaced by `gmgn-windows-host contract`.
    Unimplemented { reason: &'static str },
}

/// One op this host accepts responsibility for.
#[derive(Debug, Clone, Copy)]
pub struct Registration {
    pub op: &'static str,
    /// The fields the UI sends with this op, which this host must read.
    pub reads: &'static [&'static str],
    pub status: Status,
}

/// Every op in the contract, registered.
pub const REGISTRY: &[Registration] = &[
    Registration { op: "agent.login", reads: &[], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "agent.logout", reads: &[], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "agent.save", reads: &["hostPrompt", "planningModel", "residentPersona"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "app.language", reads: &["locale"], status: Status::Implemented },
    Registration { op: "generation.check", reads: &[], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "generation.save", reads: &["endpoint", "token"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "inbox.open", reads: &["expectedEventID", "id", "scope"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "music.connect", reads: &["id"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "music.disconnect", reads: &["id"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "music.sync", reads: &["id"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "presence.activate", reads: &["id"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "presence.catalog", reads: &["url"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "presence.import", reads: &[], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "presence.import.link", reads: &["url"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "presence.load", reads: &[], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "presence.motion", reads: &["id"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "presence.motion.import", reads: &[], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "presence.motion.install", reads: &["catalogIdentity"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "presence.motion.remove", reads: &["id"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "presence.orb.color", reads: &["blue", "green", "red"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "presence.orb.intensity", reads: &["value"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "presence.position", reads: &["expectedLayoutRevision", "expectedRevision", "position", "requestID", "worldID"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "presence.position.reset", reads: &["expectedLayoutRevision", "expectedRevision", "requestID", "worldID"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "presence.remove", reads: &["id"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "settings.load", reads: &[], status: Status::Unimplemented { reason: "needs the local settings store, which is not in this crate yet" } },
    Registration { op: "settings.open.presence", reads: &[], status: Status::Unimplemented { reason: "needs the local settings store, which is not in this crate yet" } },
    Registration { op: "shortcuts.cancel", reads: &[], status: Status::Unimplemented { reason: "needs a platform global-hotkey registration (RegisterHotKey on Windows)" } },
    Registration { op: "shortcuts.capture", reads: &["keyCode", "keyLabel", "modifiers"], status: Status::Unimplemented { reason: "needs a platform global-hotkey registration (RegisterHotKey on Windows)" } },
    Registration { op: "shortcuts.global", reads: &["value"], status: Status::Unimplemented { reason: "needs a platform global-hotkey registration (RegisterHotKey on Windows)" } },
    Registration { op: "shortcuts.media", reads: &["value"], status: Status::Unimplemented { reason: "needs a platform global-hotkey registration (RegisterHotKey on Windows)" } },
    Registration { op: "shortcuts.record", reads: &["id", "scope"], status: Status::Unimplemented { reason: "needs a platform global-hotkey registration (RegisterHotKey on Windows)" } },
    Registration { op: "shortcuts.reset", reads: &[], status: Status::Unimplemented { reason: "needs a platform global-hotkey registration (RegisterHotKey on Windows)" } },
    Registration { op: "space.default", reads: &["value"], status: Status::Unimplemented { reason: "needs the local settings store, which is not in this crate yet" } },
    Registration { op: "space.key.clear", reads: &[], status: Status::Implemented },
    Registration { op: "space.key.save", reads: &["apiKey"], status: Status::Implemented },
    Registration { op: "space.library.load", reads: &[], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "space.library.select", reads: &["id"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "space.prop.cancel", reads: &["clearNotice"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "space.prop.check", reads: &["endpoint"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "space.prop.save", reads: &["apiKey", "endpoint"], status: Status::Unimplemented { reason: "needs the daemon wire client (moves to Rust with the resident loop)" } },
    Registration { op: "speech.settings.cancel", reads: &["cancelCapabilities", "clearVoices"], status: Status::Unimplemented { reason: "needs the local settings store, which is not in this crate yet" } },
    Registration { op: "speech.settings.load", reads: &[], status: Status::Unimplemented { reason: "needs the local settings store, which is not in this crate yet" } },
    Registration { op: "stage.activity.run", reads: &["id"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.activity.stop", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.avatar.position", reads: &["axis", "value"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.avatar.reset", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.camera.reset", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.motion.activate", reads: &["id"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },  // rewrites to presence.motion
    Registration { op: "stage.motion.refresh", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.player.particles", reads: &["value"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.program.back", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.program.load", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.program.more", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.program.play", reads: &["slotIndex"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.program.replan", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.program.video", reads: &["trackID"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.props.close", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.props.delete", reads: &["objectID"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.props.filter", reads: &["placedOnly"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.props.fold", reads: &["folded", "group"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.props.hold", reads: &["point"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.props.load", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.props.nudge", reads: &["y", "z"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.props.resize", reads: &["value"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.props.return", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.props.rotate", reads: &["direction"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.props.select", reads: &["objectID"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.props.undo", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.props.withdraw", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.video.bind", reads: &["id"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.video.brightness", reads: &["value"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.video.import", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.video.mode", reads: &["id"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.video.pending.dismiss", reads: &["id"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.video.pending.play", reads: &["id"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.video.recoverStop", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.video.remove", reads: &["id"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.video.stop", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.video.toggle", reads: &["id"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "stage.video.unbind", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "tts.stop", reads: &[], status: Status::Unimplemented { reason: "needs the platform audio sink" } },
    Registration { op: "video.bind", reads: &["id", "trackID"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "video.bound.dismiss", reads: &["id"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "video.bound.play", reads: &["id"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "video.brightness", reads: &["value"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "video.choose", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "video.load", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "video.mode", reads: &["value"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "video.pause", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "video.play", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "video.recoverStop", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "video.remove", reads: &["id"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "video.select", reads: &["id"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "video.stop", reads: &[], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
    Registration { op: "video.unbind", reads: &["trackID"], status: Status::Unimplemented { reason: "needs the Unity scene/renderer, which stays in the Unity shell" } },
];

/// The registration for `op`, if the contract has one.
pub fn get(op: &str) -> Option<&'static Registration> {
    REGISTRY.iter().find(|r| r.op == op)
}

/// The migration reason recorded for `op`, for refusal messages.
pub fn reason_for(op: &str) -> Option<&'static str> {
    match get(op)?.status {
        Status::Implemented => None,
        Status::Unimplemented { reason } => Some(reason),
    }
}

/// How many ops are registered as implemented -- the migration counter.
pub fn implemented_count() -> usize {
    REGISTRY.iter().filter(|r| matches!(r.status, Status::Implemented)).count()
}

/// Assert the frozen table and the handler tree agree about what is built.
///
/// The gate in `tests/second_host_contract.rs` is the real check (it also reads
/// the contract source); this helper exists so the invariant is one function.
pub fn implemented_ops() -> Vec<&'static str> {
    REGISTRY
        .iter()
        .filter(|r| matches!(r.status, Status::Implemented))
        .map(|r| r.op)
        .collect()
}

/// The declared-implemented set, from `handlers` rather than from `REGISTRY`.
pub fn declared_implemented() -> &'static [&'static str] {
    IMPLEMENTED_OPS
}
