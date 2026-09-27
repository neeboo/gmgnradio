//! Background two-lane consolidation scheduling for VoiceMem memory.
//!
//! VoiceMem orchestration plan (2026-09-08) freezes the following daemon-side
//! behavior, which this module implements together with `memory.rs`:
//!
//! - `memory_ingest` accepts only already-delivered turn pairs into a volatile
//!   per-scope buffer. Raw transcript text is never persisted; a crash loses
//!   both the pending text and the (scope, requestID) receipts, and a restart
//!   never restores un-consolidated originals.
//! - Rust schedules automatic background consolidation per scope (the same
//!   single-writer commit pipeline as `memory_compact`): when pending turns
//!   reach the batch threshold a short batch delay applies, otherwise an idle
//!   delay applies. No user-configuration framework is added; clock/policy are
//!   internal and injectable so offline tests never wait 30 real seconds.
//! - At most one consolidation may run per scope; failures keep pending turns
//!   (no infinite retry) and surface as `memory_status.orchestration`
//!   `{state, lastError}` with stable error codes. Accepted, delivered turns
//!   consolidate independently of the short IPC connection's lifetime, which is
//!   distinct from the explicit `memory_compact` disconnect-cancellation
//!   semantics (the compact request carries a `Cancellation`; background runs
//!   never do).
//!
//! This module is intentionally a pure policy/state machine with no I/O so its
//! decision logic is testable offline with injected counts/times (the delays
//! are returned as `Duration`s and only actually slept by `memory.rs`).

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

/// Per-scope orchestration state label (frozen vocabulary of the plan:
/// idle/pending/running/unconfigured/failed).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Idle,
    Pending,
    Running,
    Unconfigured,
    Failed,
}

impl State {
    pub fn label(self) -> &'static str {
        match self {
            State::Idle => "idle",
            State::Pending => "pending",
            State::Running => "running",
            State::Unconfigured => "unconfigured",
            State::Failed => "failed",
        }
    }
}

/// Injectable scheduling policy. Defaults from the frozen plan: a short merge
/// delay after the batch threshold of 4 pending turns is reached, an idle
/// delay otherwise. Tests inject tiny delays.
#[derive(Clone, Copy, Debug)]
pub struct Policy {
    pub batch_turns: usize,
    pub batch_delay: Duration,
    pub idle_delay: Duration,
}

impl Default for Policy {
    fn default() -> Self {
        Self {
            batch_turns: 4,
            batch_delay: Duration::from_secs(2),
            idle_delay: Duration::from_secs(30),
        }
    }
}

impl Policy {
    /// Delay before a consolidation attempt for `pending_turns` pending turns.
    pub fn delay_for(&self, pending_turns: usize) -> Duration {
        if pending_turns >= self.batch_turns {
            self.batch_delay
        } else {
            self.idle_delay
        }
    }
}

pub type ScopeKey = (String, String);

#[derive(Clone, Debug)]
struct Entry {
    state: State,
    last_error: Option<&'static str>,
    /// Monotonic per scope: each schedule supersedes earlier sleeps, so an
    /// out-of-date sleeping task never starts a stale consolidation.
    generation: u64,
}

/// Outcome of one background consolidation attempt.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The consolidation committed (or a concurrent writer committed instead,
    /// `memory_conflict`): re-evaluate whatever pending turns remain.
    Committed,
    /// Provider configuration is missing: content stays volatile, nothing
    /// runs, explicit `unconfigured` state.
    Unavailable,
    /// Failed with a stable error code; pending turns are preserved.
    Failed(&'static str),
}

/// A scheduling decision handed back to the caller: sleep `delay`, then attempt
/// generation `generation` for the scope.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Decision {
    pub generation: u64,
    pub delay: Duration,
}

/// Shared per-scope orchestration registry. All mutations happen under one
/// mutex; `memory.rs` nests this lock *inside* the buffers lock on the append /
/// settle paths so a count read and the state transition are consistent (a
/// scheduling decision can never be lost between the two).
pub struct Registry {
    inner: Mutex<HashMap<ScopeKey, Entry>>,
}

impl Default for Registry {
    fn default() -> Self {
        Self::new()
    }
}

impl Registry {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<ScopeKey, Entry>> {
        self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Called (while holding the buffers lock in `memory.rs`) after pending
    /// turns changed: an ingest appended turns, an explicit compact finished,
    /// or a consolidation settled. Returns a `Decision` to sleep+run when a
    /// run should happen, `None` otherwise. A running consolidation defers to
    /// its own settle (which re-reads the live count under the same lock), so
    /// no decision is ever lost.
    pub fn turns_changed(
        &self,
        key: &ScopeKey,
        pending_turns: usize,
        configured: bool,
        policy: &Policy,
    ) -> Option<Decision> {
        let mut entries = self.lock();
        let entry = entries.entry(key.clone()).or_insert(Entry {
            state: State::Idle,
            last_error: None,
            generation: 0,
        });
        if !configured {
            entry.state = State::Unconfigured;
            entry.last_error = None;
            entry.generation = entry.generation.wrapping_add(1);
            return None;
        }
        if entry.state == State::Running {
            // The running consolidation's settle re-reads the live count under
            // the buffers lock and schedules whatever is left.
            return None;
        }
        if pending_turns == 0 {
            entry.state = State::Idle;
            entry.last_error = None;
            entry.generation = entry.generation.wrapping_add(1);
            return None;
        }
        entry.state = State::Pending;
        entry.last_error = None;
        entry.generation = entry.generation.wrapping_add(1);
        Some(Decision {
            generation: entry.generation,
            delay: policy.delay_for(pending_turns),
        })
    }

    /// A sleeping background task claims the run for `generation`. Only the
    /// newest schedule may claim; stale generations (superseded by a newer
    /// ingest or a completed settle) exit immediately.
    pub fn claim(&self, key: &ScopeKey, generation: u64) -> bool {
        let mut entries = self.lock();
        let Some(entry) = entries.get_mut(key) else {
            return false;
        };
        if entry.state != State::Pending || entry.generation != generation {
            return false;
        }
        entry.state = State::Running;
        true
    }

    /// Finalize one consolidation attempt. `pending_turns` is the live count
    /// read under the buffers lock by the caller. Returns a follow-up Decision
    /// when committed turns remain (new turns arrived while it ran).
    pub fn settle(
        &self,
        key: &ScopeKey,
        outcome: Outcome,
        pending_turns: usize,
        configured: bool,
        policy: &Policy,
    ) -> Option<Decision> {
        let mut entries = self.lock();
        let entry = entries.entry(key.clone()).or_insert(Entry {
            state: State::Idle,
            last_error: None,
            generation: 0,
        });
        entry.generation = entry.generation.wrapping_add(1);
        match outcome {
            Outcome::Unavailable => {
                entry.state = State::Unconfigured;
                entry.last_error = None;
                None
            }
            Outcome::Failed(code) => {
                entry.state = State::Failed;
                entry.last_error = Some(code);
                None
            }
            Outcome::Committed => {
                if pending_turns == 0 {
                    entry.state = State::Idle;
                    entry.last_error = None;
                    return None;
                }
                if !configured {
                    entry.state = State::Unconfigured;
                    entry.last_error = None;
                    return None;
                }
                entry.state = State::Pending;
                entry.last_error = None;
                Some(Decision {
                    generation: entry.generation,
                    delay: policy.delay_for(pending_turns),
                })
            }
        }
    }

    /// Current (state label, lastError) for `memory_status.orchestration`.
    pub fn report(&self, key: &ScopeKey) -> Option<(&'static str, Option<&'static str>)> {
        let entries = self.lock();
        entries.get(key).map(|entry| (entry.state.label(), entry.last_error))
    }

    /// Test/introspection only: the live state of a scope.
    #[cfg(test)]
    pub fn state_of(&self, key: &ScopeKey) -> Option<State> {
        self.lock().get(key).map(|entry| entry.state)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn policy(batch_turns: usize, batch_ms: u64, idle_ms: u64) -> Policy {
        Policy {
            batch_turns,
            batch_delay: Duration::from_millis(batch_ms),
            idle_delay: Duration::from_millis(idle_ms),
        }
    }

    fn key() -> ScopeKey {
        ("world-a".into(), "resident-a".into())
    }

    #[test]
    fn default_policy_matches_frozen_thresholds() {
        let policy = Policy::default();
        assert_eq!(policy.batch_turns, 4);
        assert_eq!(policy.batch_delay, Duration::from_secs(2));
        assert_eq!(policy.idle_delay, Duration::from_secs(30));
        assert_eq!(policy.delay_for(1), policy.idle_delay);
        assert_eq!(policy.delay_for(3), policy.idle_delay);
        assert_eq!(policy.delay_for(4), policy.batch_delay);
        assert_eq!(policy.delay_for(20), policy.batch_delay);
    }

    #[test]
    fn below_threshold_schedules_idle_and_unconfigured_schedules_nothing() {
        let registry = Registry::new();
        let policy = policy(4, 2, 30);
        assert_eq!(
            registry.turns_changed(&key(), 2, false, &policy),
            None,
            "no provider -> no schedule, explicit unconfigured"
        );
        assert_eq!(
            registry.report(&key()),
            Some(("unconfigured", None))
        );
        let decision = registry.turns_changed(&key(), 2, true, &policy).expect("configured");
        assert_eq!(decision.delay, Duration::from_millis(30), "below batch -> idle delay");
        assert_eq!(decision.generation, 2);
        assert_eq!(registry.report(&key()), Some(("pending", None)));
    }

    #[test]
    fn batch_threshold_uses_batch_delay_and_new_input_reschedules() {
        let registry = Registry::new();
        let policy = policy(4, 2, 30);
        let first = registry.turns_changed(&key(), 4, true, &policy).expect("batch");
        assert_eq!(first.delay, Duration::from_millis(2));
        // A newer ingest below threshold pushes the deadline back to idle.
        let second = registry.turns_changed(&key(), 2, true, &policy).expect("idle");
        assert_eq!(second.delay, Duration::from_millis(30));
        assert!(second.generation > first.generation);
        // The stale first generation can no longer claim.
        assert!(!registry.claim(&key(), first.generation));
        assert!(registry.claim(&key(), second.generation));
        // Only one run may be in flight per scope.
        assert!(!registry.claim(&key(), second.generation));
        // A turn appended while running is deferred to the settle.
        assert_eq!(registry.turns_changed(&key(), 6, true, &policy), None);
        assert_eq!(registry.state_of(&key()), Some(State::Running));
    }

    #[test]
    fn failed_settle_keeps_pending_and_exposes_stable_code() {
        let registry = Registry::new();
        let policy = policy(4, 2, 30);
        registry.turns_changed(&key(), 2, true, &policy);
        assert_eq!(
            registry.settle(&key(), Outcome::Failed("memory_compact_failed"), 2, true, &policy),
            None
        );
        assert_eq!(registry.report(&key()), Some(("failed", Some("memory_compact_failed"))));
        // A new input retries: failure clears and a fresh schedule appears.
        let retry = registry.turns_changed(&key(), 2, true, &policy).expect("retry");
        assert_eq!(retry.generation, 3);
        assert_eq!(registry.report(&key()), Some(("pending", None)));
    }

    #[test]
    fn committed_settle_reschedules_remaining_or_goes_idle() {
        let registry = Registry::new();
        let policy = policy(4, 2, 30);
        registry.turns_changed(&key(), 4, true, &policy);
        // Everything committed: idle.
        assert_eq!(
            registry.settle(&key(), Outcome::Committed, 0, true, &policy),
            None
        );
        assert_eq!(registry.state_of(&key()), Some(State::Idle));
        // New turns arrived while running: follow-up batch decision.
        registry.turns_changed(&key(), 5, true, &policy);
        let follow = registry.settle(&key(), Outcome::Committed, 5, true, &policy).expect("follow-up");
        assert_eq!(follow.delay, policy.batch_delay);
        // A committed scope whose providers vanished is explicit unconfigured.
        assert_eq!(
            registry.settle(&key(), Outcome::Committed, 3, false, &policy),
            None
        );
        assert_eq!(registry.state_of(&key()), Some(State::Unconfigured));
    }
}
