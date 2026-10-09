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
///
/// 2026-10-09 (build 229, the user's own click, unified log 18:52:57.626):
/// `presence.motion` was still refused, `detail=busy=presence.motion.stop
/// ageMs=0 isWorking=false pending=false`. That marker was neither read-kind nor
/// stale: `UnityMediaHost.settingsCommand` asked this gate (clean), then called
/// `prepareManualMotionSelection()`, which synchronously ran
/// `stopActivity` → `onActivityStopped` → `stopSelectedMotion()`, beginning
/// `presence.motion.stop` **in the same MainActor turn**, and the very next
/// statement asked the gate again. So:
///
///   * no upper bound could ever have reclaimed it — the 20 s budget here and the
///     daemon's 180 s renderer budget both only act on a marker that has
///     *outlived* its deadline, and this one had just been born;
///   * the refusal named `busy=model ageMs=0` whenever the marker lived in
///     `PresenceSettingsModel` instead, which is a dead end for diagnosis.
///
/// Hence the two facts this type now separates: `refusal` asks about **the model's
/// selection half** (`modelSelection`), never about the model's observable
/// `isWorking` (which reads also set), and `busyDetail` names the half, the op,
/// the age and the kind. Ordering — waiting for the host's own preparation — is
/// the caller's job (`UnityPresenceSettingsBridge.awaitSelectionPreparation`).
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

    /// The *other* half's marker, as `PresenceSettingsModel` reports it. The
    /// model lives in another module, so the gate cannot own this marker — it
    /// only names it. `op` is the model's own op vocabulary (`presence.remove`,
    /// `presence.motion.remove`, …) and `ageMs` is its age, so a refusal can say
    /// `side=model op=presence.remove ageMs=4312` instead of the old
    /// `busy=model ageMs=0`, which named neither the operation nor how long it
    /// had been running (2026-10-09).
    struct ModelMarker: Equatable, Sendable {
        let op: String
        let kind: Kind
        let ageMs: UInt64
    }

    /// The vocabulary the window receipt and the player log already share.
    static let codeBusy = "presence_selection_busy"
    static let codeRendererPending = "presence_renderer_pending"
    static let codeStaleCleared = "presence_selection_stale_cleared"
    /// The host waited for the selection-kind operation it began *itself*
    /// (`prepareManualMotionSelection`'s `presence.motion.stop`) instead of
    /// letting it refuse the selection it was preparing. Host-only: the daemon
    /// never emits it.
    static let codePreparationWaited = "presence_selection_preparation_waited"

    /// Upper bound on one non-read operation's hold. A marker at or past its
    /// deadline is stale; the next *selection* reclaims it (see
    /// `reclaimIfStale`) instead of discarding the click for ever.
    static let defaultBudgetMillis: UInt64 = 20_000

    /// The single non-read operation that owns the selection gate.
    private(set) var operation: Marker?
    /// Read-only operations in flight. They may overlap a selection and never
    /// refuse one; they are recorded so a snapshot can *explain* the model's
    /// observable `isWorking`, and they are never reclaimed (there is nothing to
    /// reclaim — a read cannot refuse anything).
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
    ///
    /// - Parameters:
    ///   - modelSelection: `PresenceSettingsModel.isSelectionWorking` — the
    ///     model's *selection* half (`runSelection`), and nothing else. It is a
    ///     separate fact from this gate's read slot, so a read can no longer turn
    ///     into a refusal **and** a live read can no longer mask a live model
    ///     selection. Reads (`presence.load` / `presence.catalog*` here,
    ///     `PresenceSettingsModel.runRead` there) never appear in this boolean.
    ///   - hasPendingSelection: the authority is waiting for a renderer receipt.
    func refusal(modelSelection: Bool, hasPendingSelection: Bool) -> String? {
        if operation != nil { return Self.codeBusy }
        if modelSelection { return Self.codeBusy }
        if hasPendingSelection { return Self.codeRendererPending }
        return nil
    }

    /// The identifying detail of a `presence_selection_busy` refusal.
    ///
    /// Names **which half** is in flight (`side=bridge|model`), the operation,
    /// its age and its kind, so one log line answers "到底是哪一半在飞、卡了多
    /// 久" without guessing. `side=none` is honest: the gate was asked for a
    /// detail without a marker, which the refusal predicate cannot produce.
    func busyDetail(nowMillis: UInt64, modelMarker: ModelMarker?,
                    hasPendingSelection: Bool) -> String {
        if let marker = operation {
            return "side=bridge op=\(marker.op) ageMs=\(nowMillis &- marker.startedAtMillis)"
                + " kind=\(marker.kind.rawValue) isWorking=\(modelMarker != nil)"
                + " pending=\(hasPendingSelection)"
        }
        if let marker = modelMarker {
            return "side=model op=\(marker.op) ageMs=\(marker.ageMs)"
                + " kind=\(marker.kind.rawValue) isWorking=true"
                + " pending=\(hasPendingSelection)"
        }
        return "side=none op=none ageMs=0 kind=none isWorking=false pending=\(hasPendingSelection)"
    }

    /// Non-destructive snapshot fields so the window can explain a refusal.
    var busyMarker: Marker? { operation }
    var busyOperation: String? { operation?.op }
    var busySinceMillis: UInt64? { operation?.startedAtMillis }
}
