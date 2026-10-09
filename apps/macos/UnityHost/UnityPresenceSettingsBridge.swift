import Foundation
import MotionDistribution
import os

/// Original package/motion services, explicitly scoped to the Unity data root.
/// Host owns runtime consumption; supported engines must reflect real renderers.
@MainActor
final class UnityPresenceSettingsBridge {
    let model: PresenceSettingsModel
    let runtime: StageAvatarRuntimeStore
    /// Every refusal of a manual motion selection lands here with the motion id
    /// and the named reason. `settingsCommand`'s receipt carries the same name,
    /// so one log line and one on-screen notice explain a refused 选定动作
    /// instead of the anonymous `settings_command_rejected`.
    static let log = Logger(subsystem: "ai.gmgn.radio", category: "PresenceSelection")
    private let supportedEngines: Set<String>
    private let selectionAuthority: RustPresenceSelectionClient
    private let onRuntimeChanged: (StageAvatarRuntimeSnapshot) -> Void
    /// The gate's whole lifecycle lives in this value type (see
    /// `PresenceSelectionGate`): which ops may refuse a selection, how long a
    /// marker may live, and what a late completion may clear.
    private var gate = PresenceSelectionGate()
    /// The single non-read operation that owns the selection gate.
    private var operation: Task<Void, Never>?
    /// Read-only operations (`presence.load`, `presence.catalog*`). They may
    /// overlap a selection and never refuse one (2026-10-09 regression).
    private var readOperation: Task<Void, Never>?
    private var downloadRevision: UInt64 = 0
    private var downloadState = "idle"
    private var pendingSelection: (revision: UInt64, authorityRevision: Int64)?
    /// When the pending renderer receipt was first observed. `pendingRenderer`
    /// is cleared by the renderer's own `renderer_ack` and by nothing else, so a
    /// renderer that never answers would otherwise leave the marker — and every
    /// later 选定动作 — refusing for the life of the process (2026-10-09).
    private var pendingSince: Date?
    /// Upper bound on one pending renderer receipt. Matches the daemon's own
    /// `RENDERER_ACK_BUDGET_MILLIS`: generous enough for a first-time PMX/VRM
    /// decode, still bounded. Reaching it abandons the unconfirmed proposal and
    /// restores the last confirmed selection (the daemon does the same on the
    /// same request), never promotes it.
    static let rendererAckBudget: TimeInterval = 180

    static let supportedCommands = ["presence.load", "presence.import", "presence.motion.import", "presence.activate", "presence.remove", "presence.motion", "presence.motion.remove", "presence.catalog", "presence.catalog.refresh", "presence.catalog.install", "presence.motion.install", "presence.download", "presence.import.link", "presence.orb", "presence.orb.color", "presence.orb.intensity", "presence.runtime.result"]

    init(defaults: UserDefaults, packages: PresencePackageStore, motions: MotionPackageStore,
         supportedEngines: Set<String>, productSettings: RustProductSettingsClient = .shared,
         onRuntimeChanged: @escaping (StageAvatarRuntimeSnapshot) -> Void) {
        self.supportedEngines = supportedEngines
        selectionAuthority = packages.selectionAuthority
        self.onRuntimeChanged = onRuntimeChanged
        runtime = StageAvatarRuntimeStore(packageStore: packages, motionPackageStore: motions)
        model = PresenceSettingsModel(defaults: defaults, avatarRuntime: runtime,
            presenceStore: packages, motionStore: motions, productSettings: productSettings,
            renderPolicy: "unity", supportedEngines: supportedEngines.union(["orb"]),
            playbackCompatibility: Self.playbackCompatibility, onWillActivateMotion: { _ in })
        model.onSelectionChanged = { [weak self] in self?.publish() }
    }

    static func playbackCompatibility(_ engine: PresenceEngine?, _ format: StageMotionFormat)
        -> PresenceSettingsModel.MotionCompatibility {
        if engine == .vrm && format == .vmd {
            return .incompatible("Unity 的 VRM 角色需要 VRMA 动作。")
        }
        return PresenceSettingsModel.motionCompatibility(avatarEngine: engine, motionFormat: format)
    }

    func load() { run("presence.load") { bridge in do { try await bridge.model.loadConfirmed() } catch { bridge.model.message=error.localizedDescription;bridge.model.hasError=true } } }
    func stop() { operation?.cancel(); operation = nil; readOperation?.cancel(); readOperation = nil }
    @discardableResult
    func stopSelectedMotion() -> Bool {
        _ = expireStalePendingRenderer()
        guard operation == nil,pendingSelection == nil else { return false }
        run("presence.motion.stop") { bridge in
            do { _ = try await bridge.selectionAuthority.event("stop_motion");try bridge.model.refreshEffectiveMotionForActiveAvatar() }
            catch { bridge.model.message=error.localizedDescription;bridge.model.hasError=true }
        }
        return true
    }
    func completeSelectedMotion(revision: UInt64, motionID: String) -> Bool {
        _ = expireStalePendingRenderer()
        guard operation == nil, pendingSelection == nil,
              revision == runtime.snapshot.revision,
              let motion = runtime.snapshot.motion, motion.id == motionID,
              !motion.loop
        else { return false }
        run("presence.motion.completed") { bridge in
            do { _ = try await bridge.selectionAuthority.event("motion_finished",id:motionID);try bridge.model.refreshEffectiveMotionForActiveAvatar() }
            catch { bridge.model.message=error.localizedDescription;bridge.model.hasError=true }
        }
        return true
    }
    /// Why `presence.motion` cannot start **right now**; `nil` = selectable.
    ///
    /// This is the single predicate behind the snapshot's per-row `selectable`
    /// flag, [`canSelectMotion`] and the `presence.motion` command guard. The
    /// settings rows used to be enabled on `compatible` alone, so a row drawn
    /// as selectable could still be refused here — silently, because the
    /// refusal only became the anonymous `settings_command_rejected`
    /// (2026-10-09 report: 选定动作报错 with nothing in any log). Names follow
    /// the authority's own vocabulary (`presence_renderer_pending`).
    /// The row-independent half of [`motionSelectionRefusal`]: the refusal that
    /// does not depend on which motion is asked about. Hoisted so a projection
    /// can answer it once instead of once per row.
    var selectionRefusalCode: String? {
        // A renderer receipt that never came is bounded: the marker is abandoned
        // here, before it can refuse the click, so the next 选定动作 proceeds (the
        // daemon runs the same bound on the same request and restores its own
        // confirmed selection).
        _ = expireStalePendingRenderer()
        return gate.refusal(isWorking: model.isWorking, hasPendingSelection: pendingSelection != nil)
    }
    /// Abandons a renderer receipt that outlived `rendererAckBudget`, named
    /// `presence_renderer_ack_timeout`. Only the marker is dropped — an
    /// unconfirmed proposal is never written into the confirmed state.
    @discardableResult
    private func expireStalePendingRenderer() -> Bool {
        guard let pending = pendingSelection, let since = pendingSince,
              Date().timeIntervalSince(since) > Self.rendererAckBudget else { return false }
        pendingSelection = nil; pendingSince = nil
        Self.log.error("code=presence_renderer_ack_timeout op=presence.runtime.result ageMs=\(Int(Date().timeIntervalSince(since) * 1000), privacy: .public) authorityRevision=\(pending.authorityRevision, privacy: .public)")
        return true
    }
    /// `busy=<op> ageMs=<n> isWorking=<b> pending=<b>` — the identifying detail
    /// of a `presence_selection_busy` refusal, so the log and the window receipt
    /// name what held the gate and for how long instead of just "busy".
    var selectionRefusalDetail: String {
        gate.busyDetail(nowMillis: Self.uptimeMillis(), isWorking: model.isWorking,
                        hasPendingSelection: pendingSelection != nil)
    }
    /// The refusal's identifying field: the gate diagnostic when the gate itself
    /// is why, the motion id otherwise.
    func selectionRefusalDetail(for id: String) -> String {
        selectionRefusalCode == PresenceSelectionGate.codeBusy ? selectionRefusalDetail : id
    }
    /// The identity the renderer must echo back with a receipt: the authority's
    /// own revision for the selection currently being confirmed. Stable across
    /// host republishes, unlike a per-publish counter (2026-10-09 W2).
    var rendererSelectionRevision: UInt64 {
        if let pending = pendingSelection { return UInt64(bitPattern: pending.authorityRevision) }
        return UInt64(bitPattern: selectionAuthority.confirmed?.revision ?? 0)
    }
    /// Whether a renderer receipt belongs to the pending selection: the
    /// authority's pending revision, with no other operation in flight. A
    /// receipt for a selection that is no longer pending is refused instead of
    /// clearing a newer `pendingRenderer`. With no pending selection the only
    /// receipt is the initial/restored acknowledgement, which the command path
    /// accepts without inspecting the revision.
    func acceptsRendererReceipt(revision: UInt64) -> Bool {
        guard operation == nil else { return false }
        guard let pending = pendingSelection else { return true }
        return revision == UInt64(bitPattern: pending.authorityRevision)
    }
    func motionSelectionRefusal(_ id: String) -> String? {
        // A real selection attempt is where a marker that outlived its own
        // deadline is reclaimed, named and cleared (2026-10-09: one `await` that
        // never returned answered every later click busy for ever).
        reclaimStaleSelectionMarker()
        if let code = selectionRefusalCode { return code }
        guard let motion = model.availableMotions.first(where: { $0.id == id }) else {
            return "presence_motion_unavailable"
        }
        guard model.motionCompatibility(motion) == .compatible else {
            return "presence_motion_incompatible"
        }
        return nil
    }
    func canSelectMotion(_ id: String) -> Bool { motionSelectionRefusal(id) == nil }
    var agentMotions: [WorldAgentMotionOption] {
        guard operation == nil, pendingSelection == nil,
              let engine = model.activeAvatarEngine,
              supportedEngines.contains(engine.rawValue),
              model.packages.contains(where: { $0.isActive && $0.rendererAvailable }) else { return [] }
        return model.availableMotions.filter { motion in
            model.motionCompatibility(motion) == .compatible &&
                (motion.format == .procedural || motion.url.map { FileManager.default.isReadableFile(atPath: $0.path) } == true)
        }.map { .init(id: $0.id, displayName: $0.name, format: $0.format.rawValue, loop: $0.loop) }
            .sorted { $0.id < $1.id }
    }
    private func publish() {
        let selected = runtime.snapshot
        if let state=selectionAuthority.confirmed,state.pendingRenderer {
            pendingSelection=(selected.revision,state.revision)
            if pendingSince == nil { pendingSince = Date() }
        } else { pendingSelection=nil; pendingSince=nil }
        onRuntimeChanged(selected)
    }

    var snapshot: [String: Any] {
        let orb = model.orbAppearance
        let confirmedMotionID = selectionAuthority.confirmed?.confirmedMotionID
        // One projection pass for the whole snapshot.
        //
        // The rows' `selectable` flag *is* `motionSelectionRefusal`, but asking
        // that predicate per row made every row rebuild `model.availableMotions`
        // — a filtered copy of every motion, with String/URL/ARC traffic — so
        // one snapshot cost O(rows²) copies. Measured on the real machine
        // 2026-10-09: 57 % of a 92 ms host frame inside `settingsSnapshot`
        // (`sample` stack: `settingsSnapshot` → `presenceSettings.snapshot` →
        // `motionSelectionRefusal` → `availableMotions`), up from ~52 ms
        // frames, while the renderer's asset load stalled behind the same main
        // thread. The rows below are drawn from this exact list, so the answer
        // collapses to the hoisted refusal plus the row's own compatibility —
        // same predicate, same codes, one pass.
        let motions = model.availableMotions
        let refusal = selectionRefusalCode
        return ["packages": model.packages.map { package in
            ["id": package.manifest.id, "name": package.manifest.name,
             "engine": package.manifest.engine.rawValue, "active": package.isActive, "isActive": package.isActive,
             "builtIn": package.isBuiltIn, "isBuiltIn": package.isBuiltIn,
             "detail": package.manifest.engine.rawValue + " · " + package.manifest.version,
             "author": package.manifest.author as Any? ?? NSNull(), "version": package.manifest.version,
             "thumbnailPath": package.thumbnailPath.flatMap { FileManager.default.isReadableFile(atPath: $0) ? $0 : nil } as Any? ?? NSNull(),
             "rendererAvailable": package.rendererAvailable && supportedEngines.contains(package.manifest.engine.rawValue)] as [String: Any]
        }, "motions": motions.map { motion in
            let compatibility = model.motionCompatibility(motion)
            let compatible = compatibility == .compatible
            let reason: String? = { if case .incompatible(let reason) = compatibility { return reason }; return nil }()
            return ["id": motion.id, "name": motion.name, "format": motion.format.rawValue,
                    "active": motion.id == confirmedMotionID, "builtIn": model.isBuiltInMotion(motion), "isBuiltIn": model.isBuiltInMotion(motion),
                    "detail": motion.format.rawValue, "category": MotionLibraryCategory.category(forMotionID: motion.id)?.rawValue as Any? ?? NSNull(),
                    "compatible": compatible, "reason": reason as Any? ?? NSNull(),
                    // The host's own answer to "would 选定动作 start right now",
                    // so the row can never be drawn selectable and then be refused.
                    // `motion.id` is in `motions` by construction, so the only
                    // remaining refusals are the hoisted one and incompatibility.
                    "selectable": refusal == nil && compatible] as [String: Any]
        }, "publishedMotions": model.availablePublishedMotions.map { motion in
            let state = model.publishedMotionInstallState(motion)
            let label: String = { switch state { case .installed: "已安装"; case .updateAvailable: "更新"; case .notInstalled: "安装" } }()
            return ["id": motion.id, "catalogIdentity": motion.id + "@" + motion.version, "name": motion.name, "format": motion.format,
                    "version": motion.version, "bytes": motion.bytes, "duration": motion.duration, "loop": motion.loop,
                    "installState": String(describing: state), "installLabel": label] as [String: Any]
        }, "categories": MotionLibraryCategory.allCases.map { ["id": $0.rawValue, "name": $0.title] },
         "activeMotionID": confirmedMotionID as Any? ?? NSNull(), "activeEngine": model.activeAvatarEngine?.rawValue as Any? ?? NSNull(),
         "avatarName": model.packages.first(where: \.isActive)?.manifest.name ?? "未选择角色",
         "catalogURL": model.remoteMotionCatalogURL,
         "orb": ["red": orb.red, "green": orb.green, "blue": orb.blue, "flowIntensity": orb.flowIntensity],
         "working": model.isWorking || operation != nil || readOperation != nil || pendingSelection != nil, "notice": model.message as Any? ?? NSNull(), "hasError": model.hasError,
         "downloadRevision": downloadRevision, "downloadState": downloadState, "motionNotice": model.motionListNotice as Any? ?? NSNull(),
         // Non-destructive explanation of a `presence_selection_busy` refusal:
         // which operation holds the gate and since when. `nil` = no marker.
         "busyOperation": gate.busyOperation as Any? ?? NSNull(),
         "busySinceMillis": gate.busySinceMillis as Any? ?? NSNull()]
    }

    func command(_ value: [String: Any]) -> Bool {
        guard let op = value["op"] as? String else { return false }
        if op == "presence.runtime.result" {
            // The receipt is identified by the *authority's* revision for the
            // pending selection, not by the host's ever-advancing publish
            // counter: the renderer echoes the revision it was given, and by the
            // time a real asset load finishes that counter has moved on. The old
            // equality rejected the one receipt that clears `pendingRenderer`,
            // so the host stayed busy for ever (2026-10-09).
            guard let revision = value["revision"] as? UInt64, let success = value["success"] as? Bool else { return false }
            guard let previous = pendingSelection else {
                if !success { model.message = "角色或动作加载失败，已恢复原选择。"; model.hasError = true }
                return true // Initial/restored selection also gets a real runtime receipt.
            }
            guard revision == UInt64(bitPattern: previous.authorityRevision) else { return false }
            guard operation == nil else{return false}
            run("presence.runtime.result") { bridge in
                do {
                    _ = try await bridge.selectionAuthority.event("renderer_ack",success:success,expectedRevision:previous.authorityRevision)
                    try bridge.model.refreshEffectiveMotionForActiveAvatar()
                    bridge.model.message=success ? "动作或角色已载入。" : "角色或动作加载失败，已恢复原选择。"
                    bridge.model.hasError = !success
                }catch{bridge.model.message=error.localizedDescription;bridge.model.hasError=true}
            }
            return true
        }
        let id = value["id"] as? String ?? ""
        // A pending renderer receipt that outlived its budget is abandoned so the
        // click it was refusing can proceed; the daemon applies the same bound.
        _ = expireStalePendingRenderer()
        // A manual selection is refused only by the selection gate, so a read
        // (`presence.load`, `presence.catalog*`) can no longer swallow a click.
        // Every other command keeps the old all-or-nothing guard (and now has to
        // name the read slot, which used to live in `operation`).
        if op == "presence.motion" {
            reclaimStaleSelectionMarker()
            guard selectionRefusalCode == nil else { return false }
        } else {
            guard operation == nil, readOperation == nil, pendingSelection == nil, !model.isWorking else { return false }
        }
        switch op {
        case "presence.load": load()
        case "presence.import": model.importModel()
        case "presence.motion.import": model.importMotion()
        case "presence.activate":
            guard let package = model.packages.first(where: { $0.manifest.id == id }),
                  package.rendererAvailable, supportedEngines.contains(package.manifest.engine.rawValue) else { return false }
            run("presence.activate") { bridge in
                do { try await bridge.model.activateConfirmed(package) }
                catch{bridge.model.message=error.localizedDescription;bridge.model.hasError=true}
            }
        case "presence.remove":
            guard let package = model.packages.first(where: { $0.manifest.id == id }) else { return false }
            model.remove(package)
        case "presence.motion":
            guard let motion = model.availableMotions.first(where: { $0.id == id }), model.motionCompatibility(motion) == .compatible else { return false }
            // The caller (`UnityMediaHost.settingsCommand`) already refused the
            // named cases; whatever is left is a race with an in-flight load and
            // still deserves a name (and the gate diagnostic) rather than a
            // silent `false`.
            if let refusal = motionSelectionRefusal(id) {
                Self.log.error("presence.motion refused id=\(id, privacy: .public) code=\(refusal, privacy: .public) detail=\(self.selectionRefusalDetail(for: id), privacy: .public)")
                return false
            }
            run("presence.motion") { bridge in
                do { try await bridge.model.activateMotionConfirmed(motion) }
                catch{bridge.model.message=error.localizedDescription;bridge.model.hasError=true}
            }
        case "presence.motion.remove":
            guard let motion = model.motions.first(where: { $0.id == id }) else { return false }
            model.removeMotion(motion)
        case "presence.catalog", "presence.catalog.refresh":
            if let url = value["url"] as? String { model.remoteMotionCatalogURL = url }
            run("presence.catalog", kind: .read) { await $0.model.refreshPublishedMotions() }
        case "presence.catalog.install", "presence.motion.install":
            guard let identity = value["catalogIdentity"] as? String,
                  let motion = model.publishedMotions.first(where: { $0.id + "@" + $0.version == identity }) else { return false }
            run("presence.catalog.install") { await $0.model.installPublishedMotion(motion) }
        case "presence.download", "presence.import.link":
            guard let url = value["url"] as? String, !url.isEmpty else { return false }
            model.downloadURL = url; downloadRevision &+= 1; downloadState = "downloading"
            run("presence.download") { bridge in
                await bridge.model.downloadAndInstall()
                bridge.downloadRevision &+= 1; bridge.downloadState = bridge.model.hasError ? "failed" : "succeeded"
            }
        case "presence.orb", "presence.orb.color", "presence.orb.intensity":
            if let r = value["red"] as? NSNumber, let g = value["green"] as? NSNumber, let b = value["blue"] as? NSNumber,
               [r.floatValue, g.floatValue, b.floatValue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
                model.setOrbColor(red: r.floatValue, green: g.floatValue, blue: b.floatValue)
            }
            if let flow = (value["flowIntensity"] ?? value["value"]) as? NSNumber, flow.floatValue.isFinite { model.setOrbFlowIntensity(flow.floatValue) }
        default: return false
        }
        if operation == nil {
            runtime.refresh()
            publish()
        }
        return !model.hasError
    }

    /// Monotonic millisecond clock for the gate. The gate itself takes `nowMillis`
    /// as a parameter, so its staleness arithmetic is testable without a clock.
    static func uptimeMillis() -> UInt64 { UInt64(ProcessInfo.processInfo.systemUptime * 1000) }

    /// Starts an operation against the gate.
    ///
    /// Every exit path clears the marker through `finishOperation`, and only the
    /// generation that began a marker may clear it: a completion that arrives
    /// after its marker was reclaimed must not clear the marker that replaced it.
    private func run(_ op: String, kind: PresenceSelectionGate.Kind? = nil,
                     _ body: @escaping @MainActor (UnityPresenceSettingsBridge) async -> Void) {
        let generation = gate.begin(op: op, kind: kind, nowMillis: Self.uptimeMillis())
        let resolved = kind ?? PresenceSelectionGate.Kind.classify(op: op)
        let task = Task { [weak self] in
            defer { self?.finishOperation(generation: generation) }
            guard let self else { return }
            await body(self)
        }
        if resolved == .read { readOperation = task } else { operation = task }
    }

    /// Clears the marker this generation began, refreshes and republishes. A
    /// late completion (generation no longer current) touches nothing.
    private func finishOperation(generation: UInt64) {
        guard let slot = gate.finish(generation: generation) else { return }
        switch slot {
        case .operation: operation = nil
        case .read: readOperation = nil
        }
        runtime.refresh()
        publish()
    }

    /// A marker that outlived its own deadline is cancelled, cleared and named
    /// with `presence_selection_stale_cleared`, and then the selection proceeds.
    @discardableResult
    private func reclaimStaleSelectionMarker() -> Bool {
        guard let stale = gate.reclaimIfStale(nowMillis: Self.uptimeMillis()) else { return false }
        operation?.cancel(); operation = nil
        Self.log.error("code=\(PresenceSelectionGate.codeStaleCleared, privacy: .public) op=\(stale.op, privacy: .public) ageMs=\(stale.ageMs, privacy: .public) kind=\(stale.kind.rawValue, privacy: .public)")
        return true
    }
}
