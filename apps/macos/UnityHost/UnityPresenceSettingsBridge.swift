import Foundation
import MotionDistribution

/// Original package/motion services, explicitly scoped to the Unity data root.
/// Host owns runtime consumption; supported engines must reflect real renderers.
@MainActor
final class UnityPresenceSettingsBridge {
    let model: PresenceSettingsModel
    let runtime: StageAvatarRuntimeStore
    private let supportedEngines: Set<String>
    private let selectionAuthority: RustPresenceSelectionClient
    private let onRuntimeChanged: (StageAvatarRuntimeSnapshot) -> Void
    private var operation: Task<Void, Never>?
    private var downloadRevision: UInt64 = 0
    private var downloadState = "idle"
    private var pendingSelection: (revision: UInt64, authorityRevision: Int64)?

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

    func load() { run { bridge in do { try await bridge.model.loadConfirmed() } catch { bridge.model.message=error.localizedDescription;bridge.model.hasError=true } } }
    func stop() { operation?.cancel(); operation = nil }
    @discardableResult
    func stopSelectedMotion() -> Bool {
        guard operation == nil,pendingSelection == nil else { return false }
        run { bridge in
            do { _ = try await bridge.selectionAuthority.event("stop_motion");try bridge.model.refreshEffectiveMotionForActiveAvatar() }
            catch { bridge.model.message=error.localizedDescription;bridge.model.hasError=true }
        }
        return true
    }
    func completeSelectedMotion(revision: UInt64, motionID: String) -> Bool {
        guard operation == nil, pendingSelection == nil,
              revision == runtime.snapshot.revision,
              let motion = runtime.snapshot.motion, motion.id == motionID,
              !motion.loop
        else { return false }
        run { bridge in
            do { _ = try await bridge.selectionAuthority.event("motion_finished",id:motionID);try bridge.model.refreshEffectiveMotionForActiveAvatar() }
            catch { bridge.model.message=error.localizedDescription;bridge.model.hasError=true }
        }
        return true
    }
    func canSelectMotion(_ id: String) -> Bool {
        operation == nil && pendingSelection == nil && model.availableMotions.contains {
            $0.id == id && model.motionCompatibility($0) == .compatible
        }
    }
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
        } else { pendingSelection=nil }
        onRuntimeChanged(selected)
    }

    var snapshot: [String: Any] {
        let orb = model.orbAppearance
        let confirmedMotionID = selectionAuthority.confirmed?.confirmedMotionID
        return ["packages": model.packages.map { package in
            ["id": package.manifest.id, "name": package.manifest.name,
             "engine": package.manifest.engine.rawValue, "active": package.isActive, "isActive": package.isActive,
             "builtIn": package.isBuiltIn, "isBuiltIn": package.isBuiltIn,
             "detail": package.manifest.engine.rawValue + " · " + package.manifest.version,
             "author": package.manifest.author as Any? ?? NSNull(), "version": package.manifest.version,
             "thumbnailPath": package.thumbnailPath.flatMap { FileManager.default.isReadableFile(atPath: $0) ? $0 : nil } as Any? ?? NSNull(),
             "rendererAvailable": package.rendererAvailable && supportedEngines.contains(package.manifest.engine.rawValue)] as [String: Any]
        }, "motions": model.availableMotions.map { motion in
            let compatible = model.motionCompatibility(motion) == .compatible
            let reason: String? = { if case .incompatible(let reason) = model.motionCompatibility(motion) { return reason }; return nil }()
            return ["id": motion.id, "name": motion.name, "format": motion.format.rawValue,
                    "active": motion.id == confirmedMotionID, "builtIn": model.isBuiltInMotion(motion), "isBuiltIn": model.isBuiltInMotion(motion),
                    "detail": motion.format.rawValue, "category": MotionLibraryCategory.category(forMotionID: motion.id)?.rawValue as Any? ?? NSNull(),
                    "compatible": compatible, "reason": reason as Any? ?? NSNull()] as [String: Any]
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
         "working": model.isWorking || operation != nil || pendingSelection != nil, "notice": model.message as Any? ?? NSNull(), "hasError": model.hasError,
         "downloadRevision": downloadRevision, "downloadState": downloadState, "motionNotice": model.motionListNotice as Any? ?? NSNull()]
    }

    func command(_ value: [String: Any]) -> Bool {
        guard let op = value["op"] as? String else { return false }
        if op == "presence.runtime.result" {
            guard let revision = value["revision"] as? UInt64, let success = value["success"] as? Bool,
                  revision == runtime.snapshot.revision else { return false }
            guard let previous = pendingSelection else {
                if !success { model.message = "角色或动作加载失败，已恢复原选择。"; model.hasError = true }
                return true // Initial/restored selection also gets a real runtime receipt.
            }
            guard previous.revision == revision else { return false }
            guard operation == nil else{return false}
            run { bridge in
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
        guard operation == nil, pendingSelection == nil, !model.isWorking else { return false }
        switch op {
        case "presence.load": load()
        case "presence.import": model.importModel()
        case "presence.motion.import": model.importMotion()
        case "presence.activate":
            guard let package = model.packages.first(where: { $0.manifest.id == id }),
                  package.rendererAvailable, supportedEngines.contains(package.manifest.engine.rawValue) else { return false }
            run { bridge in
                do { try await bridge.model.activateConfirmed(package) }
                catch{bridge.model.message=error.localizedDescription;bridge.model.hasError=true}
            }
        case "presence.remove":
            guard let package = model.packages.first(where: { $0.manifest.id == id }) else { return false }
            model.remove(package)
        case "presence.motion":
            guard let motion = model.availableMotions.first(where: { $0.id == id }), model.motionCompatibility(motion) == .compatible else { return false }
            run { bridge in
                do { try await bridge.model.activateMotionConfirmed(motion) }
                catch{bridge.model.message=error.localizedDescription;bridge.model.hasError=true}
            }
        case "presence.motion.remove":
            guard let motion = model.motions.first(where: { $0.id == id }) else { return false }
            model.removeMotion(motion)
        case "presence.catalog", "presence.catalog.refresh":
            if let url = value["url"] as? String { model.remoteMotionCatalogURL = url }
            run { await $0.model.refreshPublishedMotions() }
        case "presence.catalog.install", "presence.motion.install":
            guard let identity = value["catalogIdentity"] as? String,
                  let motion = model.publishedMotions.first(where: { $0.id + "@" + $0.version == identity }) else { return false }
            run { await $0.model.installPublishedMotion(motion) }
        case "presence.download", "presence.import.link":
            guard let url = value["url"] as? String, !url.isEmpty else { return false }
            model.downloadURL = url; downloadRevision &+= 1; downloadState = "downloading"
            run { bridge in
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

    private func run(_ body: @escaping @MainActor (UnityPresenceSettingsBridge) async -> Void) {
        operation = Task { [weak self] in
            guard let self else { return }
            await body(self)
            guard !Task.isCancelled else { return }
            operation = nil; runtime.refresh()
            publish()
        }
    }
}
