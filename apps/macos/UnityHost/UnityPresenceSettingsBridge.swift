import Foundation
import MotionDistribution

/// Original package/motion services, explicitly scoped to the Unity data root.
/// Host owns runtime consumption; supported engines must reflect real renderers.
@MainActor
final class UnityPresenceSettingsBridge {
    let model: PresenceSettingsModel
    let runtime: StageAvatarRuntimeStore
    private let supportedEngines: Set<String>
    private let onRuntimeChanged: (StageAvatarRuntimeSnapshot) -> Void
    private var operation: Task<Void, Never>?
    private var downloadRevision: UInt64 = 0
    private var downloadState = "idle"
    private var pendingSelection: (revision: UInt64, avatarID: String, motionID: String?)?

    static let supportedCommands = ["presence.load", "presence.import", "presence.motion.import", "presence.activate", "presence.remove", "presence.motion", "presence.motion.remove", "presence.catalog", "presence.catalog.refresh", "presence.catalog.install", "presence.motion.install", "presence.download", "presence.import.link", "presence.orb", "presence.orb.color", "presence.orb.intensity", "presence.runtime.result"]

    init(defaults: UserDefaults, packages: PresencePackageStore, motions: MotionPackageStore,
         supportedEngines: Set<String>, onRuntimeChanged: @escaping (StageAvatarRuntimeSnapshot) -> Void) {
        self.supportedEngines = supportedEngines
        self.onRuntimeChanged = onRuntimeChanged
        runtime = StageAvatarRuntimeStore(packageStore: packages, motionPackageStore: motions)
        model = PresenceSettingsModel(defaults: defaults, avatarRuntime: runtime,
            presenceStore: packages, motionStore: motions,
            playbackCompatibility: Self.playbackCompatibility, onWillActivateMotion: { _ in })
    }

    static func playbackCompatibility(_ engine: PresenceEngine?, _ format: StageMotionFormat)
        -> PresenceSettingsModel.MotionCompatibility {
        if engine == .vrm && format == .vmd {
            return .incompatible("Unity 的 VRM 角色需要 VRMA 动作。")
        }
        return PresenceSettingsModel.motionCompatibility(avatarEngine: engine, motionFormat: format)
    }

    func load() { model.load(); runtime.refresh(); publish() }
    func stop() { operation?.cancel(); operation = nil }
    @discardableResult
    func stopSelectedMotion() -> Bool {
        guard let idle = model.motions.first(where: { $0.id == MotionPackageStore.naturalIdleID })
        else { return false }
        operation?.cancel(); operation = nil
        pendingSelection = nil
        model.activateMotion(idle)
        guard !model.hasError else { return false }
        runtime.refresh()
        publish()
        return true
    }
    func completeSelectedMotion(revision: UInt64, motionID: String) -> Bool {
        guard operation == nil, pendingSelection == nil,
              revision == runtime.snapshot.revision,
              let motion = runtime.snapshot.motion, motion.id == motionID,
              !motion.loop, let url = motion.url,
              let idle = model.motions.first(where: { $0.id == MotionPackageStore.naturalIdleID })
        else { return false }
        runtime.finishOneShotMotion(at: url)
        model.activateMotion(idle)
        publish()
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
        // Natural idle is a user selection, but the humanoid renderer needs
        // the installed idle clip rather than its procedural orb marker.
        let selectedMotion = selected.motion
        let motion: StageMotionAsset?
        if selected.avatar != nil && (selectedMotion == nil || selectedMotion?.format == .procedural),
           let idle = runtime.residentIdleMotion, let url = idle.url,
           FileManager.default.fileExists(atPath: url.path) {
            motion = idle
        } else {
            motion = selectedMotion
        }
        onRuntimeChanged(StageAvatarRuntimeSnapshot(avatar: selected.avatar, motion: motion,
                                                    revision: selected.revision))
    }

    var snapshot: [String: Any] {
        let orb = model.orbAppearance
        let confirmedMotionID = pendingSelection.map { $0.motionID } ?? model.activeMotionID
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
            pendingSelection = nil
            if !success {
                if let package = model.packages.first(where: { $0.manifest.id == previous.avatarID }) { model.activate(package) }
                if let motionID = previous.motionID, let motion = model.motions.first(where: { $0.id == motionID }) { model.activateMotion(motion) }
                model.message = "角色或动作加载失败，已恢复原选择。"; model.hasError = true
                runtime.refresh(); publish()
            } else {
                model.message = "动作或角色已载入。"
                model.hasError = false
            }
            return true
        }
        let id = value["id"] as? String ?? ""
        guard operation == nil, pendingSelection == nil else { return false }
        let previousAvatarID = model.packages.first(where: \.isActive)?.manifest.id ?? PresencePackageStore.builtInOrbID
        let previousMotionID = model.activeMotionID
        switch op {
        case "presence.load": load()
        case "presence.import": model.importModel()
        case "presence.motion.import": model.importMotion()
        case "presence.activate":
            guard let package = model.packages.first(where: { $0.manifest.id == id }),
                  package.rendererAvailable, supportedEngines.contains(package.manifest.engine.rawValue) else { return false }
            model.activate(package)
            // Changing the resident is not a new request to perform the old
            // manually selected motion, even when its format is compatible.
            if !model.hasError, previousAvatarID != id,
               let idle = model.motions.first(where: { $0.id == MotionPackageStore.naturalIdleID }) {
                model.activateMotion(idle)
            }
        case "presence.remove":
            guard let package = model.packages.first(where: { $0.manifest.id == id }), !package.isBuiltIn else { return false }
            model.remove(package)
        case "presence.motion":
            guard let motion = model.availableMotions.first(where: { $0.id == id }), model.motionCompatibility(motion) == .compatible else { return false }
            model.activateMotion(motion)
        case "presence.motion.remove":
            guard let motion = model.motions.first(where: { $0.id == id }), !model.isBuiltInMotion(motion) else { return false }
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
            run(previousSelection: (previousAvatarID, previousMotionID)) { bridge in
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
            if ["presence.activate", "presence.motion", "presence.import"].contains(op), !model.hasError,
               op == "presence.motion" || previousAvatarID != runtime.snapshot.avatar?.id || previousMotionID != model.activeMotionID {
                pendingSelection = (runtime.snapshot.revision, previousAvatarID, previousMotionID)
                model.message = "正在载入角色或动作…"
            }
            publish()
        }
        return !model.hasError
    }

    private func run(previousSelection: (String, String?)? = nil,
                     _ body: @escaping @MainActor (UnityPresenceSettingsBridge) async -> Void) {
        operation = Task { [weak self] in
            guard let self else { return }
            await body(self)
            guard !Task.isCancelled else { return }
            operation = nil; runtime.refresh()
            if let previousSelection, !model.hasError {
                pendingSelection = (runtime.snapshot.revision, previousSelection.0, previousSelection.1)
            }
            publish()
        }
    }
}
