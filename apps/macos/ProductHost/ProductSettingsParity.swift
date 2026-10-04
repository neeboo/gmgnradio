import AppKit
import Foundation
import MotionDistribution

/// Projection of the original settings models. Secret replacement is input-only.
@MainActor
final class GPUISettingsParity {
    private let runtime: AppDelegate
    private let presence = PresenceSettingsModel(defaults: E2ERuntime.defaults)
    private let music = MusicAccountsModel(defaults: E2ERuntime.defaults)
    private let marble: MarbleAPIKeySettingsModel
    private let props: PropGenerationConfigurationStore
    private var operations: [String: Task<Void, Never>] = [:]
    private var syncObserver: NSObjectProtocol?
    private var recordMonitor: Any?
    private var spaceNotice: String?
    private var shortcutValidationMessage: String?
    private var propEndpoint = "http://127.0.0.1:8191"
    private var propConfigured = false
    private var propChecking = false
    private var propCheckTask: Task<Void, Never>?
    private var propCheckID: UUID?
    private var downloadRevision: UInt64 = 0
    private var downloadState = "idle"
    private var marbleMutationRevision: UInt64 = 0
    private var propSaveRevision: UInt64 = 0
    private var spaceHasError = false

    init(runtime: AppDelegate) {
        self.runtime = runtime
        let secrets = E2ERuntime.applicationSupportDirectory()
            .appendingPathComponent("ai.gmgn.radio/secrets", isDirectory: true)
        marble = MarbleAPIKeySettingsModel(provider: MarbleAPIKeyProvider(
            fileURL: secrets.appendingPathComponent("world-labs-api-key")))
        props = PropGenerationConfigurationStore(fileURL: secrets.appendingPathComponent("prop-generation.json"))
        syncObserver = NotificationCenter.default.addObserver(forName: .musicLibrarySyncDidFinish,
            object: nil, queue: .main) { [weak self] notification in
                let provider = notification.userInfo?["providerID"] as? String
                let error = notification.userInfo?["errorDescription"] as? String
                let count = notification.userInfo?["playlistCount"] as? Int
                MainActor.assumeIsolated {
                    var info: [String: Any] = [:]
                    info["providerID"] = provider; info["errorDescription"] = error; info["playlistCount"] = count
                    self?.music.handleSyncCompletion(Notification(name: .musicLibrarySyncDidFinish, userInfo: info))
                }
            }
    }

    func load() {
        presence.load()
        operation("music.load") { [weak self] in await self?.music.load() }
        loadPropConfiguration()
    }

    var snapshot: [String: Any] {
        let shortcuts = runtime.shortcutSettingsStore
        let recording = shortcuts.recordingTarget
        let orb = presence.orbAppearance
        return [
            "presence": [
                "packages": presence.packages.map { package in
                    ["id": package.manifest.id, "name": package.manifest.name,
                     "engine": package.manifest.engine.rawValue, "active": package.isActive, "isActive": package.isActive,
                     "builtIn": package.isBuiltIn, "isBuiltIn": package.isBuiltIn,
                     "detail": package.manifest.engine.rawValue + " · " + package.manifest.version,
                     "displayDetail": package.isBuiltIn ? "内置 · " + engineName(package.manifest.engine)
                        : (package.manifest.author ?? engineName(package.manifest.engine)) + " · " + package.manifest.version,
                     "author": package.manifest.author as Any? ?? NSNull(), "version": package.manifest.version,
                     "thumbnailPath": package.thumbnailPath.flatMap { FileManager.default.isReadableFile(atPath: $0) ? $0 : nil } as Any? ?? NSNull(),
                     "rendererAvailable": package.rendererAvailable] as [String: Any]
                },
                "motions": presence.availableMotions.map { motion in
                    ["id": motion.id, "name": motion.name, "format": motion.format.rawValue,
                     "active": motion.id == presence.activeMotionID,
                     "builtIn": presence.isBuiltInMotion(motion), "isBuiltIn": presence.isBuiltInMotion(motion),
                     "detail": motion.format.rawValue,
                     "category": MotionLibraryCategory.category(forMotionID: motion.id)?.rawValue as Any? ?? NSNull(),
                     "compatible": presence.motionCompatibility(motion) == .compatible,
                     "reason": motionReason(motion) as Any? ?? NSNull()] as [String: Any]
                },
                "publishedMotions": presence.availablePublishedMotions.map { motion in
                    ["id": motion.id, "catalogIdentity": motion.id + "@" + motion.version, "name": motion.name, "format": motion.format,
                     "version": motion.version, "bytes": motion.bytes, "duration": motion.duration, "loop": motion.loop,
                     "installState": String(describing: presence.publishedMotionInstallState(motion)),
                     "installLabel": installLabel(motion)] as [String: Any]
                },
                "categories": MotionLibraryCategory.allCases.map { ["id": $0.rawValue, "name": $0.title] },
                "activeMotionID": presence.activeMotionID as Any? ?? NSNull(),
                "activeEngine": presence.activeAvatarEngine?.rawValue as Any? ?? NSNull(),
                "avatarName": presence.packages.first(where: \.isActive)?.manifest.name ?? "未选择角色",
                "catalogURL": presence.remoteMotionCatalogURL,
                "orb": ["red": orb.red, "green": orb.green, "blue": orb.blue, "flowIntensity": orb.flowIntensity],
                "working": presence.isWorking, "notice": presence.message as Any? ?? NSNull(),
                "downloadRevision": downloadRevision, "downloadState": downloadState,
                "hasError": presence.hasError,
                "motionNotice": presence.motionListNotice as Any? ?? NSNull(),
            ],
            "music": [
                "providers": [MusicProviderID.netease, .qqMusic, .appleMusic].map { id in
                    ["id": id.rawValue, "name": music.providerName(id),
                     "connected": music.state(for: id) == .connected,
                     "status": music.state(for: id).rawValue] as [String: Any]
                },
                "working": music.isWorking, "notice": music.message as Any? ?? NSNull(), "hasError": music.hasError,
            ],
            "space": [
                "options": DefaultSpacePreference.allCases.map { ["id": $0.rawValue, "name": $0.title, "detail": $0.detail] },
                "defaultSpace": DefaultSpacePreference.load(defaults: E2ERuntime.defaults).rawValue,
                "credentialConfigured": marble.isConfigured,
                "notice": spaceNotice ?? marble.message as Any? ?? NSNull(),
                "propEndpoint": propEndpoint, "propCredentialConfigured": propConfigured, "propChecking": propChecking,
                "marbleMutationRevision": marbleMutationRevision, "propSaveRevision": propSaveRevision,
                "hasError": spaceNotice == nil ? marble.hasError : spaceHasError,
            ],
            "shortcuts": [
                "assignments": shortcuts.assignments.map {
                    ["id": $0.action.rawValue, "title": $0.action.title,
                     "local": $0.local.displayName, "global": $0.global.displayName] as [String: Any]
                },
                "globalEnabled": shortcuts.globalEnabled, "mediaKeysEnabled": shortcuts.mediaKeysEnabled,
                "recordingID": recording?.action.rawValue as Any? ?? NSNull(),
                "recordingScope": recording?.scope.rawValue as Any? ?? NSNull(),
                "validationMessage": shortcutValidationMessage as Any? ?? NSNull(),
                "notice": NSNull(),
            ],
        ]
    }

    func command(_ value: [String: Any]) -> Bool {
        guard let op = value["op"] as? String else { return false }
        let id = value["id"] as? String ?? ""
        switch op {
        case "presence.load": presence.load()
        case "presence.import": presence.importModel()
        case "presence.motion.import": presence.importMotion()
        case "presence.activate":
            guard let package = presence.packages.first(where: { $0.manifest.id == id }) else { return false }
            presence.activate(package)
        case "presence.remove":
            guard let package = presence.packages.first(where: { $0.manifest.id == id }) else { return false }
            presence.remove(package)
        case "presence.motion":
            guard let motion = presence.motions.first(where: { $0.id == id }) else { return false }
            presence.activateMotion(motion)
        case "presence.motion.remove":
            guard let motion = presence.motions.first(where: { $0.id == id }) else { return false }
            presence.removeMotion(motion)
        case "presence.catalog", "presence.catalog.refresh":
            if let url = value["url"] as? String { presence.remoteMotionCatalogURL = url }
            guard !presence.isWorking else { return false }
            operation("presence") { [weak self] in await self?.presence.refreshPublishedMotions() }
        case "presence.catalog.install", "presence.motion.install":
            guard let identity = value["catalogIdentity"] as? String, !presence.isWorking,
                  let motion = presence.publishedMotions.first(where: { $0.id + "@" + $0.version == identity }) else { return false }
            operation("presence") { [weak self] in await self?.presence.installPublishedMotion(motion) }
        case "presence.download", "presence.import.link":
            guard let url = value["url"] as? String, !presence.isWorking, operations["presence"] == nil else {
                downloadRevision &+= 1; downloadState = "failed"; return false
            }
            presence.downloadURL = url
            downloadRevision &+= 1; downloadState = "downloading"
            operation("presence") { [weak self] in
                guard let self else { return }
                await presence.downloadAndInstall()
                guard !Task.isCancelled else { return }
                downloadRevision &+= 1
                downloadState = presence.hasError ? "failed" : "succeeded"
            }
        case "presence.orb", "presence.orb.color", "presence.orb.intensity":
            if let r = value["red"] as? NSNumber, let g = value["green"] as? NSNumber, let b = value["blue"] as? NSNumber,
               r.floatValue.isFinite, g.floatValue.isFinite, b.floatValue.isFinite {
                presence.setOrbColor(red: r.floatValue, green: g.floatValue, blue: b.floatValue)
            }
            if let flow = value["flowIntensity"] as? NSNumber, flow.floatValue.isFinite { presence.setOrbFlowIntensity(flow.floatValue) }
            if op == "presence.orb.intensity", let flow = value["value"] as? NSNumber, flow.floatValue.isFinite { presence.setOrbFlowIntensity(flow.floatValue) }
        case "music.load": operation("music") { [weak self] in await self?.music.load() }
        case "music.connect", "music.disconnect", "music.sync":
            let provider = MusicProviderID(rawValue: id)
            guard [.netease, .qqMusic, .appleMusic].contains(provider), !music.isWorking else { return false }
            operation("music") { [weak self] in
                guard let self else { return }
                if op == "music.sync" { await music.sync(provider) }
                else if op == "music.disconnect" { await music.disconnect(provider) }
                else if provider == .appleMusic { await music.authorizeAppleMusic() }
                else { await music.connect(provider) }
            }
        case "space.default":
            guard let raw = value["value"] as? String, let choice = DefaultSpacePreference(rawValue: raw) else { return false }
            choice.save(defaults: E2ERuntime.defaults)
        case "space.key.save":
            guard let key = value["apiKey"] as? String else { return false }
            marble.replacementKey = key; marble.save(); spaceNotice = nil
            if !marble.hasError { marbleMutationRevision &+= 1 }
        case "space.key.clear":
            marble.clear(); spaceNotice = nil
            if !marble.hasError { marbleMutationRevision &+= 1 }
        case "space.prop.save": cancelPropCheck(); return saveProps(value)
        case "space.prop.cancel":
            cancelPropCheck()
            if value["clearNotice"] as? Bool == true { spaceNotice = nil; spaceHasError = false }
        case "space.prop.check": checkProps(value)
        case "shortcuts.record":
            shortcutValidationMessage = nil
            guard let action = GMGNShortcutAction(rawValue: id), let raw = value["scope"] as? String,
                  let scope = GMGNShortcutScope(rawValue: raw) else { return false }
            runtime.shortcutSettingsStore.beginRecording(action: action, scope: scope)
            installRecordingMonitor()
        case "shortcuts.cancel": shortcutValidationMessage = nil; runtime.shortcutSettingsStore.cancelRecording(); removeRecordingMonitor()
        case "shortcuts.reset": shortcutValidationMessage = nil; runtime.shortcutSettingsStore.reset(); removeRecordingMonitor()
        case "shortcuts.save":
            if let enabled = value["globalEnabled"] as? Bool { runtime.shortcutSettingsStore.globalEnabled = enabled }
            if let enabled = value["mediaKeysEnabled"] as? Bool { runtime.shortcutSettingsStore.mediaKeysEnabled = enabled }
        case "shortcuts.global", "shortcuts.media":
            guard let enabled = value["value"] as? Bool else { return false }
            if op == "shortcuts.global" { runtime.shortcutSettingsStore.globalEnabled = enabled }
            else { runtime.shortcutSettingsStore.mediaKeysEnabled = enabled }
        default: return false
        }
        return true
    }

    private func saveProps(_ value: [String: Any]) -> Bool {
        guard let text = value["endpoint"] as? String, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            spaceNotice = PropGenerationError.invalidEndpoint.localizedDescription; spaceHasError = true; return false
        }
        let replacement = (value["apiKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            operations["prop"]?.cancel()
            let previous = replacement.isEmpty ? try props.load() : nil
            let candidate = try PropGenerationConfiguration(endpoint: url, token: replacement.isEmpty ? previous?.token ?? "" : replacement)
            guard !replacement.isEmpty || candidate.endpoint == previous?.endpoint else {
                spaceNotice = "更换服务地址时请同时填写密钥。"; spaceHasError = true; return false
            }
            try props.save(candidate)
            loadPropConfiguration(); spaceNotice = "许愿机配置已保存。"; spaceHasError = false; propSaveRevision &+= 1
            NotificationCenter.default.post(name: .propGenerationConfigurationDidChange, object: nil)
            return true
        } catch let error as PropGenerationError { spaceNotice = error.localizedDescription; spaceHasError = true; return false }
        catch { spaceNotice = "许愿机配置无法保存，请检查本机存储权限。"; spaceHasError = true; return false }
    }

    private func installLabel(_ motion: PublishedMotion) -> String {
        switch presence.publishedMotionInstallState(motion) {
        case .installed: "已安装"
        case .updateAvailable: "更新"
        case .notInstalled: "安装"
        }
    }

    private func motionReason(_ motion: StageMotionAsset) -> String? {
        switch presence.motionCompatibility(motion) {
        case .compatible: nil
        case .incompatible(let reason): reason
        }
    }

    private func engineName(_ engine: PresenceEngine) -> String {
        switch engine { case .orb: "呼吸球"; case .live2D: "Live2D"; case .vrm: "VRM"; case .pmx: "PMX" }
    }

    private func loadPropConfiguration() {
        do {
            let saved = try props.load()
            propConfigured = saved != nil
            if let saved { propEndpoint = saved.endpoint.absoluteString }
        } catch { propConfigured = false; spaceNotice = "许愿机配置读取失败，现有文件已保留。"; spaceHasError = true }
    }

    private func operation(_ key: String, _ body: @escaping @MainActor () async -> Void) {
        guard operations[key] == nil else { return }
        operations[key] = Task { [weak self] in
            await body()
            self?.operations[key] = nil
        }
    }

    private func cancelPropCheck() {
        propCheckID = nil
        propCheckTask?.cancel()
        propCheckTask = nil
        propChecking = false
    }

    private func checkProps(_ value: [String: Any]) {
        cancelPropCheck()
        do {
            guard let saved = try props.load(),
                  let raw = value["endpoint"] as? String,
                  let draftURL = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  try PropGenerationConfiguration(endpoint: draftURL, token: saved.token).endpoint == saved.endpoint else {
                spaceNotice = "请先保存服务配置，再检测连接。"
                spaceHasError = true
                return
            }
            let id = UUID()
            propCheckID = id
            propChecking = true
            spaceNotice = nil
            spaceHasError = false
            propCheckTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if propCheckID == id {
                        propCheckID = nil; propCheckTask = nil; propChecking = false
                    }
                }
                do {
                    let health = try await PropGenerationClient(endpoint: saved.endpoint, token: saved.token).health()
                    guard !Task.isCancelled, propCheckID == id else { return }
                    spaceNotice = health.message
                    spaceHasError = false
                } catch {
                    guard !Task.isCancelled, propCheckID == id else { return }
                    spaceNotice = (error as? PropGenerationError)?.errorDescription
                        ?? "暂时无法连接生成服务，请检查连接后重试。"
                    spaceHasError = true
                }
            }
        } catch {
            spaceNotice = "许愿机配置无法读取，请先重新保存服务配置。"
            spaceHasError = true
        }
    }

    private func installRecordingMonitor() {
        removeRecordingMonitor()
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                self?.handleRecordingEvent(event) ?? false
            }
            return handled ? nil : event
        }
    }

    private func handleRecordingEvent(_ event: NSEvent) -> Bool {
        guard let target = runtime.shortcutSettingsStore.recordingTarget else { return false }
        if event.keyCode == 53 {
            shortcutValidationMessage = nil
            runtime.shortcutSettingsStore.cancelRecording()
            removeRecordingMonitor()
            return true
        }
        guard let combination = GMGNKeyCombination(event: event) else {
            shortcutValidationMessage = "请按一个完整的按键组合。"
            return true
        }
        if target.scope == .global && combination.modifiers.isEmpty {
            shortcutValidationMessage = "全局快捷键至少需要一个修饰键。"
            return true
        }
        runtime.shortcutSettingsStore.assign(combination, to: target.action, scope: target.scope)
        shortcutValidationMessage = nil
        removeRecordingMonitor()
        return true
    }

    private func removeRecordingMonitor() {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil
    }

    func close() {
        cancelPropCheck()
        for task in operations.values { task.cancel() }
        operations.removeAll()
        removeRecordingMonitor()
        runtime.shortcutSettingsStore.cancelRecording()
        if let syncObserver { NotificationCenter.default.removeObserver(syncObserver) }
        syncObserver = nil
    }
}
