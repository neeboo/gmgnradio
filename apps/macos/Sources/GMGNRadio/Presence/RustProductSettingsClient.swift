import Foundation

/// Main-actor confirmed view only. All I/O is detached; no UI-thread HTTP wait.
@MainActor
final class RustProductSettingsClient {
    typealias Call = @Sendable (String, Data) throws -> Data
    struct Values: Codable, Sendable {
        let locale: String; let residentPersona: String; let backgroundTurnsPerHour: Int
        let autoSpeak: Bool; let autonomyEnabled: Bool; let agentBackend: String
        let selectedWorldID: String?; let defaultSpace: String; let djHostPrompt: String; let djTakeover: Bool; let djPlanningModel: String?
        let ttsProvider: String; let ttsModel: String; let ttsVoice: String
        let asrProvider: String; let asrModel: String; let microphoneDeviceID: String?
        let orbRed: Double; let orbGreen: Double; let orbBlue: Double; let orbFlowIntensity: Double
        let remoteMotionCatalogURL: String
        let shortcutAssignments: [ShortcutAssignment]
        let globalShortcutsEnabled: Bool; let mediaKeysEnabled: Bool
        let musicConnectedProviders: [String]
        let avatarPositions: [String: [Double]]
        let stagePointCloudChoice: String
        let stageParticleSizeMultiplier: Double
        let stageLegacyImported: Bool
        let stageLyricsMode: String
        let stageLyricsResolvedMode: String
        let stageLyricsTrackID: String?
        let stageLyricsLegacyImported: Bool
    }
    struct ShortcutAssignment: Codable, Sendable {
        let action: String; let local: Combination; let global: Combination
    }
    struct Combination: Codable, Sendable {
        let keyCode: UInt16; let keyLabel: String; let modifiers: UInt
    }
    struct Snapshot: Codable, Sendable { let revision: Int64; let values: Values; let imported: Bool }
    enum SettingsError: Error { case invalidProtocol, unavailable }
    static let shared = RustProductSettingsClient(root: WorldAuthorityEndpoint.taskServiceRoot(applicationSupportBase: E2ERuntime.applicationSupportBase))
    private let call: Call
    private(set) var confirmed: Snapshot?
    private var loading: Task<Void, Never>?
    private var mutation: Task<Snapshot, Error>?
    private var mutationID: UUID?
    var onChange: (() -> Void)?
    init(call: @escaping Call) { self.call = call }
    convenience init(root: URL, allowsLaunching: Bool = false) {
        let transport = TaskdHTTPAuthorityClient(endpointFile: root.appendingPathComponent("taskd.endpoint.json").path,
            helperPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gmgn-taskd").path,
            allowsLaunching: allowsLaunching, timeout: 5)
        self.init(call: { method, data in
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SettingsError.invalidProtocol }
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: value))
        })
    }
    private func request(_ method: String, _ value: [String: Any]) async throws -> Snapshot {
        let data = try JSONSerialization.data(withJSONObject: value), call = self.call
        let output = try await Task.detached { try call(method, data) }.value
        let result = try JSONDecoder().decode(Snapshot.self, from: output)
        guard result.revision >= 0 else { throw SettingsError.invalidProtocol }
        return result
    }
    func bootstrap(legacy: [String: Any]) {
        guard loading == nil, confirmed?.imported != true else { return }
        let prior = mutation
        loading = Task {
            defer { loading = nil }
            do {
                if let prior { _ = try? await prior.value }
                if confirmed?.imported != true {
                    publish(try await request("product_settings_import", ["values": legacy]))
                }
            }
            catch { /* No candidate is promoted when the authority is unavailable. */ }
        }
    }
    func reload() async throws { publish(try await request("product_settings_read", [:])) }
    func ensureLoaded() async throws {
        await loading?.value
        if confirmed == nil { try await reload() }
    }
    private func publish(_ snapshot: Snapshot) {
        if let confirmed, snapshot.revision < confirmed.revision { return }
        confirmed = snapshot; onChange?()
        NotificationCenter.default.post(name: .init("gmgnProductSettingsConfirmed"), object: self)
    }
    func apply(_ changes: [String: Any]) async throws -> Snapshot {
        try await mutate("product_settings_apply", payload: ["changes": changes])
    }
    func shortcutEvent(_ event: [String: Any]) async throws -> Snapshot {
        try await mutate("product_settings_shortcut_event", payload: ["event": event])
    }
    func recordMusicConnection(providerID: String, connected: Bool) async throws -> Snapshot {
        try await mutate("product_settings_music_receipt", payload: ["providerID": providerID, "connected": connected])
    }
    func importStageLegacy(legacy: [String: Any]) async throws -> Snapshot {
        try await mutate("product_settings_stage_import", payload: ["legacy": legacy])
    }
    func setAvatarPosition(scope: String, axis: String, value: Double, basePosition: [Double]) async throws -> Snapshot {
        try await mutate("product_settings_stage_event", payload: ["event": ["kind":"avatarAxis", "scope":scope, "axis":axis, "value":value, "basePosition":basePosition]])
    }
    func resetAvatarPosition(scope: String) async throws -> Snapshot {
        try await mutate("product_settings_stage_event", payload: ["event": ["kind":"avatarReset", "scope":scope]])
    }
    func selectPointCloud(raw: String) async throws -> Snapshot {
        try await mutate("product_settings_stage_event", payload: ["event": ["kind":"pointCloud", "value":raw]])
    }
    func setParticleSizeMultiplier(_ value: Double) async throws -> Snapshot {
        try await mutate("product_settings_stage_event", payload: ["event": ["kind":"particleSize", "value":value]])
    }
    func setStageLyricsMode(raw: String) async throws -> Snapshot {
        try await mutate("product_settings_stage_event", payload: ["event": ["kind":"lyricsSet", "value":raw]])
    }
    func cycleStageLyricsMode() async throws -> Snapshot {
        try await mutate("product_settings_stage_event", payload: ["event": ["kind":"lyricsCycle"]])
    }
    func setStageLyricsTrack(_ id: String?) async throws -> Snapshot {
        try await mutate("product_settings_stage_event", payload: ["event": ["kind":"lyricsTrack", "trackID":id as Any? ?? NSNull()]])
    }
    static func stageLegacySnapshot(_ defaults: UserDefaults) -> [String: Any] {
        defaults.dictionaryRepresentation().filter { key,_ in
            key.hasPrefix("ai.gmgn.radio.spatial.avatar-position.") || key == "stage.point-cloud-choice" || key == "stage.particle-size-multiplier" || key == "stage.lyrics.visualMode"
        }
    }
    private func mutate(_ method: String, payload: [String: Any]) async throws -> Snapshot {
        await loading?.value
        let prior = mutation
        let id = UUID()
        let task = Task { [self] in
            if let prior { _ = try? await prior.value }
            if confirmed == nil { try await reload() }
            do {
                return try await send(method, payload: payload, requestID: id)
            } catch let WorldAuthorityError.daemon(code)
                where code == "product_settings_revision_conflict" {
                // 权威用 `expectedRevision` 做乐观并发控制。另一个写者（另一个窗口 /
                // Unity 宿主）先提交时，这里拿到的是 `product_settings_revision_conflict`。
                // 旧行为是直接抛出：用户这一次改动就丢了，而且本地 `confirmed.revision`
                // 仍是旧的，之后每次保存都会再冲突一次（界面看着像"设置保存不了"）。
                //
                // 按权威的要求**重读一次最新快照再重放一次**。`requestID` 原样复用：
                // 冲突是在 request 记录落库**之前**返回的（product_settings.rs 先比
                // `expectedRevision` 再 INSERT），所以这个 id 在权威那边还没有记录，
                // 重放不会撞 `product_settings_request_conflict`。
                //
                // 只重试一次：第二次仍冲突说明又有人抢先，如实把这个错误抛出去，
                // 不吞、不循环、不降级写本地。
                try await reload()
                return try await send(method, payload: payload, requestID: id)
            }
        }
        mutation = task; mutationID = id
        defer { if mutationID == id { mutation = nil; mutationID = nil } }
        return try await task.value
    }
    /// 用**当前** `confirmed.revision` 提交一次写。冲突恢复路径会先 `reload()` 再调它，
    /// 所以两次调用读到的 `expectedRevision` 一定不同。
    private func send(_ method: String, payload: [String: Any], requestID: UUID) async throws -> Snapshot {
        guard let confirmed else { throw SettingsError.unavailable }
        var requestPayload = payload
        requestPayload["requestID"] = requestID.uuidString
        requestPayload["expectedRevision"] = confirmed.revision
        let result = try await request(method, requestPayload)
        publish(result)
        return result
    }
    func bindWorldCatalog(_ ids: [String]) async throws { publish(try await request("product_settings_bind_catalog", ["worldIDs": ids])) }
    func selectWorld(_ id: String?) async throws { _ = try await apply(["selectedWorldID": id as Any? ?? NSNull()]) }
    static func legacySnapshot(_ defaults: UserDefaults) -> [String: Any] {
        var value: [String: Any] = [:]
        for (old, key) in [("resident.persona.v1","residentPersona"), ("resident.background-turns-per-hour.v1","backgroundTurnsPerHour"),
            ("unity.ui.locale","locale"), ("agentConversation.autoSpeakReplies","autoSpeak"), ("unity.agent.autoSpeakReplies","autoSpeak"),
            ("dj.agent.host-prompt","djHostPrompt"), ("dj.agent.takeover-enabled","djTakeover"), ("dj.agent.planning-model","djPlanningModel"),
            ("speech.rust.tts.provider","ttsProvider"), ("speech.rust.asr.provider","asrProvider"),
            ("voice.microphoneDeviceID","microphoneDeviceID"), ("agentConversation.backend","agentBackend"), ("space.default-selection","defaultSpace"),
            ("resident.autonomous.enabled.v1","autonomyEnabled")] {
            if let stored = defaults.object(forKey: old) { value[key] = stored }
        }
        if let catalog=defaults.string(forKey: "gmgn.presence.motion.catalog-url") { value["remoteMotionCatalogURL"]=catalog }
        if let data = defaults.data(forKey: "gmgn.keyboardShortcuts.v1"),
           let decoded = try? JSONDecoder().decode([ShortcutAssignment].self, from: data),
           decoded.count == 8, Set(decoded.map(\.action)).count == 8,
           let entries = try? JSONSerialization.jsonObject(with: data) { value["shortcutAssignments"] = entries }
        for (old,key) in [("gmgn.keyboardShortcuts.globalEnabled","globalShortcutsEnabled"),("gmgn.keyboardShortcuts.mediaKeysEnabled","mediaKeysEnabled"),("music.connected-provider-ids","musicConnectedProviders")] {
            if let stored = defaults.object(forKey: old) { value[key] = stored }
        }
        let tts = value["ttsProvider"] as? String ?? "bailian", asr = value["asrProvider"] as? String ?? "bailian"
        if defaults.object(forKey: "orb.appearance.red") != nil {
            for (old, key) in [("orb.appearance.red","orbRed"),("orb.appearance.green","orbGreen"),("orb.appearance.blue","orbBlue"),("orb.appearance.flow-intensity","orbFlowIntensity")] {
                value[key]=defaults.double(forKey: old)
            }
        }
        for (old, key) in ["speech.rust.\(tts).tts.model":"ttsModel", "speech.rust.\(tts).voiceID":"ttsVoice", "speech.rust.\(asr).asr.model":"asrModel"] {
            if let stored = defaults.object(forKey: old) { value[key] = stored }
        }
        return value
    }
}
