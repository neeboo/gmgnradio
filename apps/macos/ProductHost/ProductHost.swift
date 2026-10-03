import AppKit
import Foundation
import SwiftUI

/// GPUI owns NSApplication's delegate and run loop. This object retains the
/// original product runtime and forwards lifecycle; no probe stores or agent
/// services are constructed here.
@MainActor
final class GPUIProductHost: NSObject, NSMenuDelegate {
    let runtime: AppDelegate
    private var started = false
    private var stopped = false
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var submissions: [UUID: UInt64] = [:]
    private var completed: Set<UUID> = []
    private var cancelledRequests: Set<UInt64> = []
    private var latestRequestID: UInt64?
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var events: [[String: Any]] = []
    private var draft = ""
    private var statusNotice: String?
    private var observedScope: String?
    private var navigationRevision: UInt64 = 0
    private var navigationMode = "space"
    private var navigationPanel: String?
    private lazy var settings = GPUIProductSettings(runtime: runtime)
    private lazy var programSelection = runtime.gpuiMakeProgramSelection()

    override init() {
        runtime = AppDelegate()
        super.init()
        runtime.gpuiOpenSettings = { [weak self] in _ = self?.action("showSettings") }
        runtime.gpuiResidentRecovery = { [weak self] submission, notice in
            guard let self, let id = submissions[submission.id], !completed.contains(submission.id) else { return }
            completed.insert(submission.id)
            // Display recovery only; the existing loop retains delivery,
            // cancellation and world authorization semantics.
            draft = draft.isEmpty ? submission.text : draft + "\n" + submission.text
            statusNotice = notice
            enqueue(["requestID": id, "kind": cancelledRequests.contains(id) ? "cancelled" : "failure", "message": notice])
        }
    }

    func start() -> Bool {
        guard !started, !stopped else { return false }
        started = true
        runtime.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification,
                                                          object: NSApplication.shared))
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: ProductIdentity.displayName)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuildMenu(menu)
        return true
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        settings.close()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        if started {
            runtime.gpuiCancelResident()
            runtime.gpuiDetachSurface()
            runtime.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification,
                                                          object: NSApplication.shared))
        }
        runtime.gpuiResidentRecovery = nil
        runtime.gpuiOpenSettings = nil
        NotificationCenter.default.removeObserver(runtime)
        settingsWindow?.close()
        settingsWindow = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func send(requestID: UInt64, text: String, attachmentIDs: [String]? = nil) -> Bool {
        guard started, !stopped, !submissions.values.contains(requestID) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let submission: ResidentChatSubmission
        if let attachmentIDs {
            guard let built = runtime.gpuiBuildSubmission(text: trimmed, attachmentIDs: attachmentIDs) else { return false }
            submission = built
        } else { submission = ResidentChatSubmission(text: trimmed) }
        guard submission.canSend else { return false }
        submissions[submission.id] = requestID
        observedScope = runtime.gpuiChatSnapshot()["scope"] as? String
        latestRequestID = requestID
        draft = ""
        statusNotice = nil
        enqueue(["requestID": requestID, "kind": "accepted", "text": submission.text])
        tasks[requestID] = Task { [weak self] in
            guard let self else { return }
            guard !stopped, !Task.isCancelled else {
                runtime.gpuiRestoreAttachments(submission.attachments)
                return
            }
            defer { tasks[requestID] = nil }
            do {
                try await runtime.gpuiSubmit(submission)
            } catch {
                runtime.gpuiRestoreAttachments(submission.attachments)
                guard !stopped, !completed.contains(submission.id) else { return }
                completed.insert(submission.id)
                draft = submission.text
                statusNotice = error.localizedDescription
                enqueue(["requestID": requestID, "kind": "failure", "message": error.localizedDescription])
            }
        }
        return true
    }

    func cancel(requestID: UInt64) -> Bool {
        guard started, !stopped,
              latestRequestID == requestID,
              let submissionID = submissions.first(where: { $0.value == requestID })?.key,
              !completed.contains(submissionID) else { return false }
        // A completed reply may not have been polled yet; reject its delayed
        // cancel before it can stop a newer native/background resident turn.
        let currentLines = runtime.gpuiChatSnapshot()["transcript"] as? [[String: String]] ?? []
        guard !currentLines.contains(where: {
            $0["turnID"] == submissionID.uuidString && $0["role"] == "agent"
        }) else { return false }
        cancelledRequests.insert(requestID)
        tasks[requestID]?.cancel()
        // Cancels the existing resident run, including its real tool/voice
        // ownership. Never manufacture a separate GPUI conversation run.
        runtime.gpuiCancelResident()
        if !completed.contains(submissionID) {
            completed.insert(submissionID)
            enqueue(["requestID": requestID, "kind": "cancelled", "message": "已停止本次回复。"])
        }
        return true
    }

    func snapshot() -> [String: Any] {
        var state = runtime.gpuiChatSnapshot()
        if let scope = state["scope"] as? String {
            if let old = observedScope, old != scope {
                for task in tasks.values { task.cancel() }
                tasks.removeAll()
                submissions.removeAll()
                completed.removeAll()
                cancelledRequests.removeAll()
                latestRequestID = nil
                draft = ""
                statusNotice = nil
                events.removeAll()
            }
            observedScope = scope
        }
        let lines = state["transcript"] as? [[String: String]] ?? []
        for line in lines where line["role"] == "agent" {
            guard let raw = line["turnID"], let id = UUID(uuidString: raw),
                  let requestID = submissions[id], !completed.contains(id) else { continue }
            completed.insert(id)
            enqueue(["requestID": requestID, "kind": "reply", "text": line["text"] ?? ""])
        }
        for line in lines where line["role"] == "notice" && line["text"] == ResidentChatTranscriptLine.silentCompletionText {
            guard let raw = line["turnID"], let id = UUID(uuidString: raw),
                  let requestID = submissions[id], !completed.contains(id) else { continue }
            completed.insert(id)
            enqueue(["requestID": requestID, "kind": "completed"])
        }
        state["draft"] = draft
        let settingsState = settings.snapshot
        state["settings"] = settingsState
        var stageState = runtime.gpuiStageSnapshot()
        if let presence = settingsState["presence"] as? [String: Any] {
            stageState["motions"] = ["avatarName": presence["avatarName"] ?? NSNull(),
                "categories": presence["categories"] ?? [], "items": presence["motions"] ?? [],
                "activeID": presence["activeMotionID"] ?? NSNull(), "isWorking": presence["working"] ?? false,
                "notice": presence["motionNotice"] ?? NSNull(), "message": presence["notice"] ?? NSNull()]
        }
        stageState["stageRadioPluginEnabled"] = RadioPluginAvailability.isEnabled()
        state["stage"] = stageState
        state["stageProgramRail"] = runtime.gpuiProgramSnapshot(programSelection)
        state["propEditor"] = runtime.gpuiPropSnapshot()
        let autonomy = runtime.gpuiAutonomySnapshot()
        state["autonomy"] = autonomy
        if let stopped = autonomy["stopped"] as? Bool { state["autonomyStopped"] = stopped }
        state["inbox"] = runtime.gpuiInboxSnapshot()
        let attachments = runtime.gpuiAttachmentSnapshot()
        state["attachments"] = (attachments["attachments"] as? [[String: String]] ?? []).map { image in
            ["id": image["id"] ?? "", "path": image["path"] ?? "", "name": image["name"] ?? "", "fileName": image["name"] ?? "",
             "previewPath": image["path"] ?? ""]
        }
        state["attachmentsPreparing"] = attachments["isPreparing"]
        state["attachmentError"] = attachments["error"]
        state["isPreparing"] = attachments["isPreparing"]
        state["error"] = attachments["error"]
        state["contextID"] = state["scope"]
        state["uiNavigation"] = ["revision": navigationRevision, "mode": navigationMode,
            "panel": navigationPanel as Any? ?? NSNull(), "settingsPage": navigationSettingsPage]
        if let latest = lines.last(where: { $0["role"] == "agent" })?["text"], (state["reply"] as? String ?? "").isEmpty {
            state["reply"] = latest
        }
        if let statusNotice { state["statusNotice"] = statusNotice }
        let result: [String: Any] = ["state": state, "events": events]
        events.removeAll(keepingCapacity: true)
        let visible = Set(lines.compactMap { $0["turnID"].flatMap(UUID.init(uuidString:)) })
        for id in completed.subtracting(visible) {
            if let request = submissions.removeValue(forKey: id) { cancelledRequests.remove(request) }
            completed.remove(id)
        }
        return result
    }

    func action(_ action: String) -> Bool {
        guard started, !stopped else { return false }
        switch action {
        case "showLiveCam": return navigate(mode: "liveCam")
        case "showStage": return navigate(mode: "space")
        case "showPlayer": return navigate(mode: "player")
        case "showSettings": return navigate(mode: navigationMode, panel: "settings")
        case "showNotifications": return navigate(mode: navigationMode, panel: "inbox")
        case "toggleDecoration":
            guard navigate(mode: "space") else { return false }
            return runtime.gpuiPropCommand(["op": "stage.props.toggle"])
        default: break
        }
        return runtime.gpuiPerformAction(action)
    }

    private func navigate(mode: String, panel: String? = nil) -> Bool {
        if mode == "space" || mode == "player" {
            let actual = runtime.gpuiStageSnapshot()["mode"] as? String
            if actual != mode, !runtime.gpuiToggleDestination() { return false }
        }
        navigationMode = mode; navigationPanel = panel
        navigationRevision &+= 1
        return true
    }

    private var navigationSettingsPage: String {
        switch GMGNSettingsNavigation.shared.page {
        case .presence: "presence"; case .music: "music"; case .space: "space"
        case .shortcuts: "shortcuts"; case .agent: "agent"
        }
    }

    func attachSurface(_ container: NSView, fullStage: Bool) -> Bool {
        guard runtime.gpuiAttachSurface(container, fullStage: fullStage) else { return false }
        navigationMode = fullStage ? runtime.gpuiStageSnapshot()["mode"] as? String ?? "space" : "liveCam"
        return true
    }

    func reopen() -> Bool {
        navigate(mode: navigationMode)
    }

    func settingsCommand(_ value: [String: Any]) -> Bool {
        guard started, !stopped else { return false }
        if let op = value["op"] as? String, op.hasPrefix("stage.") {
            if op == "stage.destination.toggle" { return runtime.gpuiToggleDestination() }
            if op.hasPrefix("stage.autonomy.") { return runtime.gpuiAutonomyCommand(value) }
            if op.hasPrefix("stage.program.") || op == "stage.playlist.open" {
                return runtime.gpuiProgramCommand(value, selection: programSelection)
            }
            if op.hasPrefix("stage.props.") { return runtime.gpuiPropCommand(value) }
            if op == "stage.motion.refresh" {
                return settings.command(["op": "presence.load"])
            }
            if op == "stage.motion.activate" {
                var command = value
                command["op"] = "presence.motion"
                return settings.command(command)
            }
            return runtime.gpuiStageCommand(value)
        }
        switch value["op"] as? String {
        case "chat.send":
            guard let id = value["requestID"] as? NSNumber, let text = value["text"] as? String,
                  let ids = value["attachmentIDs"] as? [String] else { return false }
            return send(requestID: id.uint64Value, text: text, attachmentIDs: ids)
        case "chat.attachments.pick", "chat.attachments.paste", "chat.attachments.import", "chat.attachments.remove":
            return runtime.gpuiAttachmentCommand(value)
        case "chat.voice.begin": runtime.beginResidentVoiceFromStage(); return true
        case "chat.voice.finish": runtime.finishResidentVoiceFromStage(); return true
        case "chat.speech.stop": runtime.gpuiStopSpeech(); return true
        case "chat.focus": runtime.gpuiChatFocus(); return true
        case "chat.task.stop": return runtime.gpuiPerformAction("stopResident")
        case "inbox.open":
            guard let id = value["id"] as? String, let scope = value["scope"] as? String else { return false }
            return runtime.gpuiOpenInboxEntry(id: id, scope: scope)
        case "inbox.restore": runtime.gpuiRestoreInbox(); return true
        default: break
        }
        return settings.command(value)
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu(menu) }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for entry in SystemResidentMenuPolicy.entries(isRadioPluginEnabled: RadioPluginAvailability.isEnabled()) {
            let title: String
            let action: String
            switch entry {
            case .showLiveCam: title = "显示小窗"; action = "showLiveCam"
            case .enterSpace: title = "进入空间"; action = "showStage"
            case .toggleDecoration:
                title = StageDecorationMenuTitle.resolve(isDecorating: StageDecorationMenuStore.shared.isDecorating)
                action = "toggleDecoration"
            case .openPlayer: title = "打开播放器"; action = "showPlayer"
            case .settings: title = "设置…"; action = "showSettings"
            case .quit: title = "退出 gmgn radio"; action = "quit"
            }
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.representedObject = action
            item.target = self
            menu.addItem(item)
        }
    }

    @objc private func menuAction(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String else { return }
        if name == "quit" { NSApplication.shared.terminate(nil) }
        else { _ = action(name) }
    }

    private func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        let root = GMGNSettingsView(shortcutSettings: runtime.shortcutSettingsStore,
            connectRealtimeVoice: { [weak runtime] in runtime?.connectRealtimeVoice($0) },
            disconnectRealtimeVoice: { [weak runtime] in runtime?.disconnectRealtimeVoice() },
            agentConfigurationChanged: { [weak runtime] in runtime?.refreshAgentConfiguration() })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "设置"
        window.identifier = NSUserInterfaceItemIdentifier("gmgn.settings")
        window.contentView = NSHostingView(rootView: root)
        window.contentMinSize = NSSize(width: 540, height: 440)
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func enqueue(_ event: [String: Any]) {
        events.append(event)
        if events.count > 128 { events.removeFirst(events.count - 128) }
    }
}

/// The same settings models and Rust voice RPC used by the original page.
/// Authentication/login and microphone capture are deliberately not invoked.
@MainActor
private final class GPUIProductSettings {
    private let runtime: AppDelegate
    private let agent = AgentSettingsModel(microphoneDevices: [], defaultMicrophoneDeviceID: nil)
    private let speech = RustSpeechPreferences(defaults: E2ERuntime.defaults)
    private let client = RustVoiceClient(root: E2ERuntime.productSupportDirectory()
        .appendingPathComponent("TaskService", isDirectory: true))
    private let previewStatus = AgentSpeechStatusStore()
    private lazy var parity = GPUISettingsParity(runtime: runtime)
    private var preview: RustSpeechSynthesizer?
    private var capabilities: RustVoiceCapabilities?
    private var capabilitiesTask: Task<Void, Never>?
    private var accountTask: Task<Void, Never>?
    private var voicesTask: Task<Void, Never>?
    private var provider: RustVoiceProvider
    private var model: String
    private var voiceID: String
    private var voices: [RustVoiceOption] = []
    private var notice: String?
    private var loadingCapabilities = false
    private var loadingVoices = false
    private var generation: UInt64 = 0

    init(runtime: AppDelegate) {
        self.runtime = runtime
        let saved = RustSpeechPreferences(defaults: E2ERuntime.defaults)
            .configuration(for: "tts", includesEnvironment: false)
        provider = saved.provider
        model = saved.model ?? ""
        voiceID = saved.voiceID
    }

    var snapshot: [String: Any] {
        let service = AgentConversationService.shared
        let resident = ResidentPreferences()
        let dj = DJAgentPreferences()
        let installed = Set(service.installedBackends().map(\.kind))
        let providerCaps = capabilities?.providers.first(where: { $0.id == provider.rawValue })
        // Only credential presence crosses the ABI. The existing credentials
        // remain owned by preferences/environment and are used solely by RPC.
        let credentialConfigured = !speech.configuration(provider: provider, for: "tts").apiKey.isEmpty
        let availableProviders = capabilities?.providers.filter { !$0.ttsModels.isEmpty }.map {
            ["id": $0.id, "name": providerName($0.id)]
        } ?? []
        var result: [String: Any] = [
            "agent": [
                "backendID": service.effectiveBackendID.rawValue,
                "backends": AgentConversationBackends.all.map { backend in
                    ["id": backend.kind.rawValue, "name": backend.displayName,
                     "installed": installed.contains(backend.kind)] as [String: Any]
                },
                "residentPersona": resident.persona,
                "hostPrompt": dj.hostPrompt(),
                "takeoverEnabled": dj.takeoverEnabled(),
                "planningModel": dj.planningModel() ?? "",
                "autonomyEnabled": UserDefaults.standard.bool(forKey: "resident.autonomous.enabled.v1"),
                "backgroundTurnsPerHour": resident.backgroundTurnsPerHour,
                "budgetOptions": Array(0...ResidentPreferences.maximumBackgroundTurnsPerHour),
                "autoSpeak": service.preferenceStore.autoSpeakReplies,
                "notice": agent.message as Any? ?? NSNull(),
            ],
            "tts": [
                "providerID": provider.rawValue,
                "providers": availableProviders,
                "modelID": model,
                "models": (providerCaps?.ttsModels ?? []).map { ["id": $0.id, "name": $0.name] },
                "voiceID": voiceID,
                "voices": voices.map { ["id": $0.id, "name": $0.name] },
                "loading": loadingCapabilities || loadingVoices,
                "notice": previewStatus.lastErrorMessage ?? notice as Any? ?? NSNull(),
                "isSpeaking": previewStatus.isSpeaking,
                "credentialConfigured": credentialConfigured,
                "catalogLoaded": capabilities != nil,
            ],
        ]
        for (key, value) in parity.snapshot { result[key] = value }
        let asr = speech.configuration(for: "asr", includesEnvironment: false)
        let asrCaps = capabilities?.providers.first(where: { $0.id == asr.provider.rawValue })
        result["asr"] = ["providerID": asr.provider.rawValue, "modelID": asr.model ?? "",
            "providers": capabilities?.providers.filter { !$0.asrModels.isEmpty }.map { ["id": $0.id, "name": providerName($0.id)] } ?? [],
            "models": (asrCaps?.asrModels ?? []).map { ["id": $0.id, "name": $0.name] },
            "credentialConfigured": !speech.configuration(for: "asr").apiKey.isEmpty,
            "catalogLoaded": capabilities != nil, "captureTestPaused": true] as [String: Any]
        var agentValue = result["agent"] as? [String: Any] ?? [:]
        agentValue["codexState"] = agent.codexState.isSignedIn ? "signedIn" : agent.codexState == .unavailable ? "unavailable" : "signedOut"
        agentValue["working"] = agent.isWorking
        result["agent"] = agentValue
        return result
    }

    func command(_ value: [String: Any]) -> Bool {
        guard let op = value["op"] as? String else { return false }
        switch op {
        case "settings.load":
            agent.refreshConversationBackends()
            loadCapabilities()
            parity.load()
        case "agent.status", "agent.login", "agent.logout":
            guard !agent.isWorking, accountTask == nil else { return false }
            accountTask = Task { [weak self] in
                guard let self else { return }
                defer { accountTask = nil }
                if op == "agent.login" { await agent.connectCodex() }
                else if op == "agent.logout" { await agent.disconnectCodex() }
                else { await agent.refresh() }
            }
        case "asr.provider", "asr.save":
            guard let raw = (value["providerID"] ?? value["id"]) as? String,
                  let selected = RustVoiceProvider(rawValue: raw),
                  let caps = capabilities?.providers.first(where: { $0.id == raw }), !caps.asrModels.isEmpty else { return false }
            let old = speech.configuration(provider: selected, for: "asr", includesEnvironment: false)
            let chosen = value["modelID"] as? String ?? old.model ?? caps.defaultASRModel ?? ""
            guard caps.asrModels.contains(where: { $0.id == chosen }) else { return false }
            let replacement = (value["apiKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            speech.save(RustVoiceConfiguration(provider: selected, apiKey: replacement.isEmpty ? old.apiKey : replacement,
                voiceID: old.voiceID, model: chosen), for: "asr")
        case "agent.save":
            // Use the original model validation/persistence and notify the
            // original runtime. No credentials, provider or login override.
            if let raw = value["backendID"] as? String {
                guard let backend = AgentConversationBackendID(rawValue: raw) else { return false }
                agent.selectConversationBackend(backend)
            }
            if let persona = value["residentPersona"] as? String {
                agent.residentPersona = persona
                agent.saveResidentPersona()
            }
            if let text = value["hostPrompt"] as? String { agent.hostPrompt = text; agent.savePrompt() }
            if let enabled = value["takeoverEnabled"] as? Bool { agent.takeoverEnabled = enabled }
            if let text = value["planningModel"] as? String { agent.planningModel = text }
            if value["takeoverEnabled"] != nil || value["planningModel"] != nil { agent.saveAgentConfiguration() }
            if let enabled = value["autoSpeak"] as? Bool { agent.setAutoSpeakAgentReplies(enabled) }
            if let budget = value["backgroundTurnsPerHour"] as? Int { _ = agent.saveBackgroundTurnsPerHour(budget) }
            if let enabled = value["autonomyEnabled"] as? Bool {
                UserDefaults.standard.set(enabled, forKey: "resident.autonomous.enabled.v1")
            }
            NotificationCenter.default.post(name: Notification.Name("gmgnResidentAutonomyChanged"), object: nil)
            runtime.refreshAgentConfiguration()
        case "tts.provider":
            guard let raw = (value["id"] ?? value["providerID"]) as? String,
                  let selected = RustVoiceProvider(rawValue: raw) else { return false }
            stopVoiceWork()
            provider = selected
            let saved = speech.configuration(provider: selected, for: "tts", includesEnvironment: false)
            model = saved.model ?? capabilities?.providers.first(where: { $0.id == raw })?.defaultTTSModel ?? ""
            voiceID = saved.voiceID
            voices = []
            notice = nil
        case "tts.refresh":
            if value["providerID"] != nil {
                guard let configuration = selectedConfiguration(value) else { return false }
                refreshVoices(configuration: configuration)
            } else { refreshVoices() }
        case "tts.save", "tts.preview":
            guard let configuration = selectedConfiguration(value) else { return false }
            provider = configuration.provider
            model = configuration.model ?? ""
            voiceID = configuration.voiceID
            preview?.stopSpeaking()
            if op == "tts.save" {
                let savedKey = speech.configuration(provider: provider, for: "tts", includesEnvironment: false).apiKey
                let replacement = (value["apiKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                speech.save(RustVoiceConfiguration(provider: provider, apiKey: replacement.isEmpty ? savedKey : replacement,
                    voiceID: voiceID, model: model), for: "tts")
                notice = "已保存。"
            } else {
                let synthesizer = RustSpeechSynthesizer(configuration: { configuration },
                    statusStore: previewStatus, client: client)
                preview = synthesizer
                synthesizer.speak("你好，这是当前选中的声音。欢迎来到你的生活空间。")
            }
        case "tts.stop": preview?.stopSpeaking(); preview = nil
        default: return parity.command(value)
        }
        return true
    }

    private func selectedConfiguration(_ value: [String: Any]) -> RustVoiceConfiguration? {
        guard let raw = value["providerID"] as? String, let selected = RustVoiceProvider(rawValue: raw),
              let modelID = value["modelID"] as? String,
              let caps = capabilities?.providers.first(where: { $0.id == raw }),
              caps.ttsModels.contains(where: { $0.id == modelID }),
              let voice = value["voiceID"] as? String else {
            notice = "请先加载模型列表并选择有效模型。"
            return nil
        }
        let available = speech.configuration(provider: selected, for: "tts")
        let replacement = (value["apiKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return RustVoiceConfiguration(provider: selected, apiKey: replacement.isEmpty ? available.apiKey : replacement,
            voiceID: voice.trimmingCharacters(in: .whitespacesAndNewlines), model: modelID)
    }

    private func loadCapabilities() {
        capabilitiesTask?.cancel()
        loadingCapabilities = true
        notice = nil
        capabilitiesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await client.capabilities()
                try Task.checkCancellation()
                capabilities = loaded
                if model.isEmpty { model = loaded.providers.first(where: { $0.id == provider.rawValue })?.defaultTTSModel ?? "" }
                loadingCapabilities = false
                refreshVoices()
            } catch {
                guard !Task.isCancelled else { return }
                loadingCapabilities = false
                notice = "模型列表暂时无法加载，不会更改已有配置。"
            }
        }
    }

    private func refreshVoices(configuration override: RustVoiceConfiguration? = nil) {
        voicesTask?.cancel()
        generation &+= 1
        let lease = generation
        let available = speech.configuration(provider: provider, for: "tts")
        let configuration = override ?? RustVoiceConfiguration(provider: provider, apiKey: available.apiKey,
            voiceID: voiceID, model: model.isEmpty ? nil : model)
        guard configuration.provider == .bailian || !configuration.apiKey.isEmpty else {
            voices = []
            loadingVoices = false
            notice = "该服务尚未配置密钥，请在原语音设置中配置后刷新。"
            return
        }
        loadingVoices = true
        voicesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await client.listVoices(configuration: configuration)
                try Task.checkCancellation()
                guard generation == lease, provider == configuration.provider else { return }
                voices = loaded
                loadingVoices = false
                notice = loaded.isEmpty ? "当前列表没有可用声音，可填写自定义声音 ID。" : "声音列表已加载。"
            } catch {
                guard !Task.isCancelled, generation == lease else { return }
                loadingVoices = false
                notice = "声音列表暂时无法加载，请检查服务额度或网络后刷新。"
            }
        }
    }

    private func stopVoiceWork() {
        generation &+= 1
        voicesTask?.cancel(); voicesTask = nil
        loadingVoices = false
        preview?.stopSpeaking(); preview = nil
        previewStatus.lastErrorMessage = nil
    }

    func close() {
        parity.close()
        accountTask?.cancel(); accountTask = nil
        stopVoiceWork()
        capabilitiesTask?.cancel(); capabilitiesTask = nil
        loadingCapabilities = false
    }

    private func providerName(_ id: String) -> String {
        switch id { case "bailian": "百炼"; case "elevenlabs": "ElevenLabs"; case "fish": "Fish Audio"; default: id }
    }
}

private func withProductHost<T: Sendable>(_ pointer: UnsafeMutableRawPointer?, _ body: @MainActor (GPUIProductHost) -> T) -> T? {
    guard Thread.isMainThread, let pointer else { return nil }
    let address = UInt(bitPattern: pointer)
    return MainActor.assumeIsolated {
        body(Unmanaged<GPUIProductHost>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue())
    }
}

@_cdecl("gmgn_product_host_create")
func gmgnProductHostCreate() -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread else { return nil }
    E2ERuntime.bootstrap()
    let address = MainActor.assumeIsolated { UInt(bitPattern: Unmanaged.passRetained(GPUIProductHost()).toOpaque()) }
    return UnsafeMutableRawPointer(bitPattern: address)
}

@_cdecl("gmgn_product_host_start")
func gmgnProductHostStart(_ pointer: UnsafeMutableRawPointer?) -> Int32 { withProductHost(pointer) { $0.start() ? 1 : 0 } ?? 0 }

@_cdecl("gmgn_product_host_shutdown")
func gmgnProductHostShutdown(_ pointer: UnsafeMutableRawPointer?) -> Int32 { withProductHost(pointer) { $0.shutdown(); return 1 } ?? 0 }

@_cdecl("gmgn_product_host_destroy")
func gmgnProductHostDestroy(_ pointer: UnsafeMutableRawPointer?) -> Int32 {
    guard Thread.isMainThread, let pointer else { return 0 }
    let address = UInt(bitPattern: pointer)
    return MainActor.assumeIsolated {
        let host = Unmanaged<GPUIProductHost>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeRetainedValue()
        host.shutdown()
        return 1
    }
}

@_cdecl("gmgn_product_host_action")
func gmgnProductHostAction(_ pointer: UnsafeMutableRawPointer?, _ action: UnsafePointer<CChar>?) -> Int32 {
    guard let action else { return 0 }
    let name = String(cString: action)
    return withProductHost(pointer) { $0.action(name) ? 1 : 0 } ?? 0
}

@_cdecl("gmgn_product_host_settings_command")
func gmgnProductHostSettingsCommand(_ pointer: UnsafeMutableRawPointer?, _ json: UnsafePointer<CChar>?) -> Int32 {
    guard Thread.isMainThread, let json,
          let data = String(cString: json).data(using: .utf8), data.count <= 256 * 1024,
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
    return withProductHost(pointer) { $0.settingsCommand(value) ? 1 : 0 } ?? 0
}

@_cdecl("gmgn_product_host_chat_send")
func gmgnProductHostChatSend(_ pointer: UnsafeMutableRawPointer?, _ requestID: UInt64, _ text: UnsafePointer<CChar>?) -> Int32 {
    guard let text else { return 0 }
    let message = String(cString: text)
    return withProductHost(pointer) { $0.send(requestID: requestID, text: message) ? 1 : 0 } ?? 0
}

@_cdecl("gmgn_product_host_chat_cancel")
func gmgnProductHostChatCancel(_ pointer: UnsafeMutableRawPointer?, _ requestID: UInt64) -> Int32 {
    withProductHost(pointer) { $0.cancel(requestID: requestID) ? 1 : 0 } ?? 0
}

@_cdecl("gmgn_product_host_snapshot")
func gmgnProductHostSnapshot(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
    let address: UInt? = withProductHost(pointer) { host in
        guard let data = try? JSONSerialization.data(withJSONObject: host.snapshot(), options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return strdup(text).map { UInt(bitPattern: $0) }
    } ?? nil
    return address.flatMap { UnsafeMutablePointer<CChar>(bitPattern: $0) }
}

@_cdecl("gmgn_product_host_chat_poll")
func gmgnProductHostChatPoll(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? { gmgnProductHostSnapshot(pointer) }

@_cdecl("gmgn_product_host_string_free")
func gmgnProductHostStringFree(_ string: UnsafeMutablePointer<CChar>?) { free(string) }

@_cdecl("gmgn_product_host_reopen")
func gmgnProductHostReopen(_ pointer: UnsafeMutableRawPointer?, _ hasVisibleWindows: Int32) -> Int32 {
    withProductHost(pointer) { $0.reopen() ? 1 : 0 } ?? 0
}

@_cdecl("gmgn_product_host_attach_surface")
func gmgnProductHostAttachSurface(_ pointer: UnsafeMutableRawPointer?, _ container: UnsafeMutableRawPointer?, _ fullStage: Int32) -> Int32 {
    guard let container else { return 0 }
    let address = UInt(bitPattern: container)
    return withProductHost(pointer) {
        let view = Unmanaged<NSView>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue()
        return $0.attachSurface(view, fullStage: fullStage != 0) ? 1 : 0
    } ?? 0
}

@_cdecl("gmgn_product_host_surface_visibility")
func gmgnProductHostSurfaceVisibility(_ pointer: UnsafeMutableRawPointer?, _ visible: Int32, _ occluded: Int32) -> Int32 {
    withProductHost(pointer) { $0.runtime.gpuiSurfaceVisibility(visible != 0, occluded: occluded != 0) ? 1 : 0 } ?? 0
}

@_cdecl("gmgn_product_host_surface_rotate")
func gmgnProductHostSurfaceRotate(_ pointer: UnsafeMutableRawPointer?, _ yaw: Float, _ pitch: Float) -> Int32 {
    guard yaw.isFinite, pitch.isFinite else { return 0 }
    return withProductHost(pointer) { $0.runtime.gpuiRotateSurface(yaw: yaw, pitch: pitch); return 1 } ?? 0
}
