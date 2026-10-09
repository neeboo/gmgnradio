import Foundation

/// The one state machine behind "would 选定动作 start right now".
///
/// Hoisted out of `UnityPresenceSettingsBridge` so the marker's whole lifecycle
/// — which operations are entitled to refuse a selection, how long a marker may
/// live, and what a late completion may clear — is a value type a harness can
/// drive with no window, renderer or daemon (`tools/test-presence-selection-gate.swift`).
///
/// 2026-10-09 (build 228): a manual selection was answered
/// `presence_selection_busy` while the only thing running was a *read*
/// (`presence.load`'s `bind` of the whole catalog, revision 41 × 16 packages),
/// and the refusal discarded the click. The same marker had no upper bound:
/// one `await` that never returned (an authority call with no timeout, a
/// `URLSession` download) made every later click busy forever. Both are
/// properties of this type, not of the caller.
///
/// What is deliberately **not** here: any relaxation of serialisation between
/// selections. A `selection` or `write` operation still refuses a selection for
/// as long as it runs; only a `read` is exempt, and only because it never owns
/// the authority's selection state.
struct PresenceSelectionGate: Equatable {
    /// Which slot a completion must clear.
    enum Slot: Equatable {
        case operation
        case read
    }

    /// Which refusal an operation is entitled to raise. A `read` never owns the
    /// selection gate; `selection` and `write` do (and are treated identically
    /// here — the distinction is documentary).
    enum Kind: String, Equatable, Sendable {
        case selection
        case read
        case write

        /// Read-only ops are exactly the ones that bind/project state and leave
        /// the authority's selection untouched. `presence.catalog.install` and
        /// `presence.motion.install` are installs, not catalog reads, so they
        /// stay writes.
        static func classify(op: String) -> Kind {
            switch op {
            case "presence.load", "presence.catalog", "presence.catalog.refresh":
                return .read
            case "presence.motion", "presence.activate", "presence.motion.stop",
                 "presence.motion.completed", "presence.runtime.result":
                return .selection
            default:
                return .write
            }
        }
    }

    struct Marker: Equatable, Sendable {
        let op: String
        let kind: Kind
        let generation: UInt64
        let startedAtMillis: UInt64
        let deadlineMillis: UInt64
    }

    /// A marker that outlived its own deadline and was reclaimed by the next
    /// selection. Named `presence_selection_stale_cleared` at the call site.
    struct StaleClear: Equatable, Sendable {
        let op: String
        let kind: Kind
        let ageMs: UInt64
    }

    /// The vocabulary the window receipt and the player log already share.
    static let codeBusy = "presence_selection_busy"
    static let codeRendererPending = "presence_renderer_pending"
    static let codeStaleCleared = "presence_selection_stale_cleared"

    /// Upper bound on one non-read operation's hold. A marker at or past its
    /// deadline is stale; the next *selection* reclaims it (see
    /// `reclaimIfStale`) instead of discarding the click for ever.
    static let defaultBudgetMillis: UInt64 = 20_000

    /// The single non-read operation that owns the selection gate.
    private(set) var operation: Marker?
    /// Read-only operations in flight. They may overlap a selection and never
    /// refuse one; they only explain `model.isWorking`.
    private(set) var reads: [Marker] = []
    private(set) var generation: UInt64 = 0
    private(set) var staleClearCount: UInt64 = 0

    /// Records a new operation and returns the generation its completion must
    /// present. Bumping the generation is what makes a late completion of a
    /// reclaimed operation unable to clear the marker that replaced it.
    @discardableResult
    mutating func begin(op: String, kind: Kind? = nil, nowMillis: UInt64,
                        budgetMillis: UInt64 = PresenceSelectionGate.defaultBudgetMillis) -> UInt64 {
        generation &+= 1
        let marker = Marker(op: op, kind: kind ?? Kind.classify(op: op), generation: generation,
                            startedAtMillis: nowMillis, deadlineMillis: nowMillis &+ budgetMillis)
        switch marker.kind {
        case .read: reads.append(marker)
        case .selection, .write: operation = marker
        }
        return generation
    }

    /// Clears the marker this generation began, and only that marker. A late
    /// completion (a generation that is no longer current) clears nothing.
    @discardableResult
    mutating func finish(generation: UInt64) -> Slot? {
        if operation?.generation == generation {
            operation = nil
            return .operation
        }
        if let index = reads.firstIndex(where: { $0.generation == generation }) {
            reads.remove(at: index)
            return .read
        }
        return nil
    }

    /// A *selection* reclaims a marker that outlived its own deadline: it is
    /// cancelled, cleared and named, and then the selection continues. Reads are
    /// never reclaimed here — they cannot refuse a selection in the first place.
    mutating func reclaimIfStale(nowMillis: UInt64) -> StaleClear? {
        guard let marker = operation, nowMillis >= marker.deadlineMillis else { return nil }
        operation = nil
        generation &+= 1
        staleClearCount &+= 1
        return StaleClear(op: marker.op, kind: marker.kind,
                          ageMs: nowMillis &- marker.startedAtMillis)
    }

    /// `presence_renderer_pending` is a different fact from busy: the authority
    /// is waiting for a renderer receipt, not for a host operation.
    func refusal(isWorking: Bool, hasPendingSelection: Bool) -> String? {
        if operation != nil { return Self.codeBusy }
        // A read explains `model.isWorking`: `presence.catalog`'s refresh sets
        // the model's own working flag while it runs. Do not let that read turn
        // into a refusal (2026-10-09 regression).
        if isWorking && reads.isEmpty { return Self.codeBusy }
        if hasPendingSelection { return Self.codeRendererPending }
        return nil
    }

    /// The identifying detail of a `presence_selection_busy` refusal.
    func busyDetail(nowMillis: UInt64, isWorking: Bool, hasPendingSelection: Bool) -> String {
        let op = operation?.op ?? (isWorking ? "model" : "none")
        let age = operation.map { nowMillis &- $0.startedAtMillis } ?? 0
        return "busy=\(op) ageMs=\(age) isWorking=\(isWorking) pending=\(hasPendingSelection)"
    }

    /// Non-destructive snapshot fields so the window can explain a refusal.
    var busyOperation: String? { operation?.op }
    var busySinceMillis: UInt64? { operation?.startedAtMillis }
}
