import Foundation
import Testing
@testable import GMGNRadio

@MainActor private final class PrivateAgentSettingsFixture {
    let daemon: PrivateMusicAuthorityFixture
    let settings: RustProductSettingsClient
    let defaults: UserDefaults
    let suite: String
    let secrets: FileSpeechSecretStore
    private init(_ daemon: PrivateMusicAuthorityFixture, _ settings: RustProductSettingsClient, _ defaults: UserDefaults, _ suite: String) {
        self.daemon=daemon;self.settings=settings;self.defaults=defaults;self.suite=suite
        secrets=FileSpeechSecretStore(directory:daemon.root.appendingPathComponent("native-private-secrets"))
    }
    static func start() async throws -> PrivateAgentSettingsFixture {
        let daemon=try await PrivateMusicAuthorityFixture.start()
        let suite="gmgn-agent-settings-private-"+UUID().uuidString
        let defaults=try #require(UserDefaults(suiteName:suite))
        let settings=RustProductSettingsClient(root:daemon.root)
        try await settings.ensureLoaded()
        return PrivateAgentSettingsFixture(daemon,settings,defaults,suite)
    }
    deinit { UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite) }
    func model(account: any CodexAccountServicing) -> AgentSettingsModel {
        AgentSettingsModel(account:account,preferences:DJAgentPreferences(defaults:defaults,settings:settings),
            residentPreferences:ResidentPreferences(defaults:defaults,settings:settings))
    }
    var speech: RustSpeechPreferences { RustSpeechPreferences(defaults:defaults,settings:settings,secrets:secrets) }
    func confirmed(_ predicate: (RustProductSettingsClient.Values) -> Bool) async throws {
        let deadline=Date().addingTimeInterval(5)
        while settings.confirmed.map({predicate($0.values)}) != true {
            guard Date()<deadline else {throw RustProductSettingsClient.SettingsError.unavailable}
            try await Task.sleep(for:.milliseconds(10))
        }
    }
    func reopen() async throws -> RustProductSettingsClient {
        let client=RustProductSettingsClient(root:daemon.root);try await client.ensureLoaded();return client
    }
    func persistedValues() async throws -> RustProductSettingsClient.Values {
        let database=daemon.root.appendingPathComponent("tasks.sqlite3").path
        let data=try await Task.detached {
            let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/sqlite3")
            process.arguments=["-readonly",database,"SELECT value FROM product_settings WHERE profile='product';"]
            let output=Pipe();process.standardOutput=output
            try process.run();let bytes=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            guard process.terminationStatus==0 else {throw RustProductSettingsClient.SettingsError.unavailable}
            return bytes
        }.value
        return try JSONDecoder().decode(RustProductSettingsClient.Values.self,from:data)
    }
}

@Test
func defaultDJPreferenceCoversACompleteRadioShow() {
    let prompt = DJAgentPreferences.defaultHostPrompt

    #expect(prompt.count > 320)
    #expect(prompt.contains("节目结构"))
    #expect(prompt.contains("歌曲事实"))
    #expect(prompt.contains("重新编排"))
    #expect(prompt.contains("长期偏好"))
}

@Test
func realtimeDJPromptCombinesIdentityPreferenceToolsAndLiveContext()
    throws
{
    let context = RealtimeDJContext(
        playback: PlaybackContext(
            currentTrack: TrackReference(
                id: "track-1",
                title: "Night Drive",
                artist: "Example"
            ),
            upcomingTrackIDs: ["track-2"],
            conversationMode: .ambient,
            programID: "program-1"
        ),
        showPlanSummary: "深夜慢慢升温",
        hostHint: ProgramHostHint(
            shouldTalkBefore: true,
            maxSentenceCount: 2,
            selectionReason: "让夜晚慢慢升温",
            currentTrack: TrackReference(
                id: "track-1",
                title: "Night Drive",
                artist: "Example"
            ),
            nextTrack: TrackReference(
                id: "track-2",
                title: "City Lights",
                artist: "Next Artist"
            ),
            facts: ["收录于 Example Album"],
            transitionIntent: "从克制过渡到更有节奏"
        ),
        hostPreference: "少说一点，切歌要果断。",
        immediateUserInstruction: "下一首更有节奏",
        visualMood: .pulse,
        agentControl: DJAgentRadioState(
            takeoverEnabled: true,
            playbackState: "playing",
            activeTrackID: "track-1",
            activeSlotIndex: 0,
            program: []
        )
    )

    let prompt = try DJRealtimePromptBuilder().build(context: context)

    #expect(prompt.contains("gmgn radio 的现场 DJ"))
    #expect(prompt.contains("少说一点，切歌要果断。"))
    #expect(prompt.contains("read_radio_state"))
    #expect(prompt.contains("search_music"))
    #expect(prompt.contains("replan_program"))
    #expect(prompt.contains("每次口播最多两句"))
    #expect(prompt.contains("中文通常不超过 40 个字"))
    #expect(prompt.contains("下一首更有节奏"))
    #expect(prompt.contains("Night Drive"))
    #expect(prompt.contains("接管已开启"))
    #expect(prompt.contains("当前歌曲开场需要主持"))
    #expect(prompt.contains("最多 2 句"))
    #expect(prompt.contains("从克制过渡到更有节奏"))
    #expect(prompt.contains("收录于 Example Album"))
}

@Test
func realtimeDJPromptUsesTheDefaultHostPreferenceWithoutContext()
    throws
{
    let prompt = try DJRealtimePromptBuilder().build(context: nil)

    #expect(prompt.contains(DJAgentPreferences.defaultHostPrompt))
    #expect(prompt.contains("调用工具后根据返回状态继续主持"))
}

@Test
func trackOpeningRequestOnlyTriggersForPlannedHostMoments() {
    let talkHint = ProgramHostHint(
        shouldTalkBefore: true,
        maxSentenceCount: 4,
        selectionReason: "把气氛带起来",
        currentTrack: TrackReference(
            id: "track-2",
            title: "City Lights",
            artist: "Next Artist"
        ),
        nextTrack: nil,
        facts: [],
        transitionIntent: nil
    )
    let quietHint = ProgramHostHint(
        shouldTalkBefore: false,
        maxSentenceCount: 2,
        selectionReason: "保持留白",
        currentTrack: talkHint.currentTrack,
        nextTrack: nil,
        facts: [],
        transitionIntent: nil
    )

    let builder = DJTrackOpeningRequestBuilder()

    #expect(builder.instruction(for: talkHint)?.contains("最多 2 句") == true)
    #expect(builder.instruction(for: talkHint)?.contains("新歌已经开始播放") == true)
    #expect(builder.instruction(for: talkHint)?.contains("read_current_track") == true)
    #expect(builder.instruction(for: talkHint)?.contains("previousTrack") == true)
    #expect(builder.instruction(for: talkHint)?.contains("nextTrack") == true)
    #expect(builder.instruction(for: quietHint) == nil)
    #expect(
        builder.instruction(for: quietHint, forceForProgramBeat: true)?
            .contains("新歌已经开始播放") == true
    )
}

@MainActor
@Test
func agentSettingsLoadsCodexLoginAndPersistsTheHostPrompt() async throws {
    let account = CodexAccountServiceStub(
        state: .signedIn(method: "ChatGPT")
    )
    let fixture=try await PrivateAgentSettingsFixture.start()
    defer {withExtendedLifetime(fixture){}}
    let defaults=fixture.defaults
    let model=fixture.model(account:account)

    await model.load()
    model.hostPrompt = "少说一点，多留意时间和用户刚才说的话。"
    model.savePrompt()
    try await fixture.confirmed {$0.djHostPrompt==model.hostPrompt}
    let reopened=try await fixture.reopen()

    #expect(model.codexState == .signedIn(method: "ChatGPT"))
    #expect(
        reopened.confirmed?.values.djHostPrompt
            == "少说一点，多留意时间和用户刚才说的话。"
    )
    #expect(defaults.string(forKey:DJAgentPreferences.hostPromptKey)==nil)
}

@MainActor
@Test
func agentSettingsPersistsTakeoverAndPlanningModel() async throws {
    let fixture=try await PrivateAgentSettingsFixture.start()
    defer {withExtendedLifetime(fixture){}}
    let defaults=fixture.defaults
    let model=fixture.model(account:CodexAccountServiceStub(state:.signedOut))

    model.takeoverEnabled = true
    model.planningModel = "gpt-5.4"
    model.saveAgentConfiguration()

    try await fixture.confirmed {$0.djTakeover && $0.djPlanningModel=="gpt-5.4"}
    let reopened=try await fixture.reopen()
    let reloaded=AgentSettingsModel(account:CodexAccountServiceStub(state:.signedOut),
        preferences:DJAgentPreferences(defaults:fixture.defaults,settings:reopened),
        residentPreferences:ResidentPreferences(defaults:fixture.defaults,settings:reopened))
    #expect(reloaded.takeoverEnabled)
    #expect(reloaded.planningModel == "gpt-5.4")
    #expect(defaults.string(forKey:DJAgentPreferences.planningModelKey)==nil)
}

@MainActor
@Test
func agentSettingsStartsCodexLoginAndRefreshesTheState() async throws {
    let account = CodexAccountServiceStub(state: .signedOut)
    let fixture=try await PrivateAgentSettingsFixture.start()
    defer {withExtendedLifetime(fixture){}}
    let model=fixture.model(account:account)

    await model.connectCodex()

    #expect(account.loginCount == 1)
    #expect(model.codexState == .signedIn(method: "ChatGPT"))
}

@MainActor
@Test
func agentSettingsLogsOutOfCodexAndReturnsToSignedOut() async throws {
    let account = CodexAccountServiceStub(
        state: .signedIn(method: "ChatGPT")
    )
    let fixture=try await PrivateAgentSettingsFixture.start()
    defer {withExtendedLifetime(fixture){}}
    let model=fixture.model(account:account)

    await model.disconnectCodex()

    #expect(account.logoutCount == 1)
    #expect(model.codexState == .signedOut)
}

@MainActor
@Test
func agentSettingsPersistsStandardVoiceWithoutKeychainPrompts()
    async throws
{
    let fixture=try await PrivateAgentSettingsFixture.start()
    defer {withExtendedLifetime(fixture){}}
    let defaults=fixture.defaults
    try await fixture.speech.save(.init(provider:.elevenlabs,apiKey:"sk-elevenlabs",voiceID:"voice-night",model:"eleven_multilingual_v2"),for:"tts")
    let reopened=try await fixture.reopen()
    let preferences=RustSpeechPreferences(defaults:defaults,settings:reopened,secrets:fixture.secrets)
    let configuration=preferences.configuration(for:"tts",includesEnvironment:false)
    #expect(configuration.provider == .elevenlabs)
    #expect(configuration.voiceID == "voice-night")
    #expect(configuration.apiKey == "sk-elevenlabs")
    #expect(configuration.model == "eleven_multilingual_v2")
    let persisted=try await fixture.persistedValues()
    #expect(persisted.ttsProvider=="elevenlabs")
    #expect(persisted.ttsModel=="eleven_multilingual_v2")
    #expect(persisted.ttsVoice=="voice-night")
    #expect(!String(decoding:try JSONEncoder().encode(persisted),as:UTF8.self).contains("sk-elevenlabs"))
    #expect(fixture.secrets.read(provider:"elevenlabs")=="sk-elevenlabs")
    #expect(defaults.string(forKey:"voice.elevenlabs.apiKey")==nil)
    #expect(preferences.configuration(for:"tts",includesEnvironment:false,includesSecrets:false).apiKey.isEmpty)
}

@MainActor
@Test
func standardVoiceMetadataDoesNotExposePrivateCredentials() async throws {
    let fixture=try await PrivateAgentSettingsFixture.start()
    defer {withExtendedLifetime(fixture){}}
    try await fixture.speech.save(.init(provider:.fish,apiKey:"private-token",voiceID:"reference",model:"s2.1-pro-free"),for:"tts")
    let metadata=fixture.speech.configuration(for:"tts",includesEnvironment:false,includesSecrets:false)
    #expect(metadata.provider == .fish)
    #expect(metadata.voiceID == "reference")
    #expect(metadata.apiKey.isEmpty)
    #expect(fixture.secrets.read(provider:"fish")=="private-token")
}

@MainActor
@Test
func standardVoiceRejectsInvalidPurposeWithoutChangingAuthorityOrSecrets() async throws {
    let fixture=try await PrivateAgentSettingsFixture.start()
    defer {withExtendedLifetime(fixture){}}
    let revision=fixture.settings.confirmed?.revision
    await #expect(throws:RustProductSettingsClient.SettingsError.self) {
        try await fixture.speech.save(.init(apiKey:"private-token",model:"invalid"),for:"realtime")
    }
    #expect(fixture.settings.confirmed?.revision==revision)
    #expect(fixture.secrets.read(provider:"bailian")==nil)
}

@MainActor @Test
func standardVoiceRejectedModelRestoresPrivateCredentialAndConfirmedSettings() async throws {
    let fixture=try await PrivateAgentSettingsFixture.start()
    defer {withExtendedLifetime(fixture){}}
    let original=fixture.speech.configuration(for:"tts",includesEnvironment:false,includesSecrets:false)
    try await fixture.speech.save(.init(apiKey:"original-private-key",voiceID:original.voiceID,model:original.model),for:"tts")
    let revision=fixture.settings.confirmed?.revision
    await #expect(throws:(any Error).self) {
        try await fixture.speech.save(.init(apiKey:"rejected-private-key",voiceID:original.voiceID,model:"unknown-model"),for:"tts")
    }
    #expect(fixture.settings.confirmed?.revision==revision)
    #expect(fixture.secrets.read(provider:"bailian")=="original-private-key")
    let reopened=try await fixture.reopen()
    #expect(reopened.confirmed?.revision==revision)
    #expect(reopened.confirmed?.values.ttsModel==original.model)
}

@MainActor
@Test
func agentSettingsSwitchesProviderAndStoresBailianKeyLocally()
    async throws
{
    let fixture=try await PrivateAgentSettingsFixture.start()
    defer {withExtendedLifetime(fixture){}}
    let defaults=fixture.defaults
    let original=fixture.speech.configuration(for:"tts",includesEnvironment:false,includesSecrets:false)
    try await fixture.speech.save(.init(provider:.bailian,apiKey:"sk-bailian",voiceID:original.voiceID,model:original.model),for:"tts")
    let reopened=try await fixture.reopen()
    let preferences=RustSpeechPreferences(defaults:defaults,settings:reopened,secrets:fixture.secrets)
    let configuration=preferences.configuration(for:"tts",includesEnvironment:false)

    #expect(configuration.provider == .bailian)
    #expect(configuration.apiKey == "sk-bailian")
    #expect(configuration.model == original.model)
    #expect(configuration.voiceID == original.voiceID)
    #expect(fixture.secrets.read(provider:"bailian")=="sk-bailian")
    #expect(
        defaults.string(forKey: "voice.bailian.apiKey")
            == nil
    )
}
@MainActor
@Test
func agentSettingsPersistsTheSelectedMicrophone() async throws {
    let fixture=try await PrivateAgentSettingsFixture.start()
    defer {withExtendedLifetime(fixture){}}
    let defaults=fixture.defaults
    _=try await fixture.settings.apply(["microphoneDeviceID":"PD200X"])
    let reloaded=try await fixture.reopen()
    #expect(fixture.settings.confirmed?.values.microphoneDeviceID == "PD200X")
    #expect(reloaded.confirmed?.values.microphoneDeviceID == "PD200X")
    #expect(try await fixture.persistedValues().microphoneDeviceID == "PD200X")
    #expect(
        defaults.string(
            forKey: "voice.microphoneDeviceID"
        ) == nil
    )
}

@MainActor
@Test
func standardASRChoicePersistsIndependentlyOfTTS() async throws {
    let fixture=try await PrivateAgentSettingsFixture.start()
    defer {withExtendedLifetime(fixture){}}
    let original=fixture.speech.configuration(for:"tts",includesEnvironment:false,includesSecrets:false)
    try await fixture.speech.save(.init(provider:.elevenlabs,apiKey:"private-asr-key",model:"scribe_v2_realtime"),for:"asr")
    let reopened=try await fixture.reopen()
    let preferences=RustSpeechPreferences(defaults:fixture.defaults,settings:reopened,secrets:fixture.secrets)
    let asr=preferences.configuration(for:"asr",includesEnvironment:false)
    let tts=preferences.configuration(for:"tts",includesEnvironment:false,includesSecrets:false)
    #expect(asr.provider == .elevenlabs)
    #expect(asr.model == "scribe_v2_realtime")
    #expect(asr.apiKey == "private-asr-key")
    let persisted=try await fixture.persistedValues()
    #expect(persisted.asrProvider=="elevenlabs")
    #expect(persisted.asrModel=="scribe_v2_realtime")
    #expect(tts.provider == original.provider)
    #expect(tts.model == original.model)
    #expect(tts.voiceID == original.voiceID)
}

@Test
func realtimeVoiceConfigurationValidatesEachProviderCredentials() {
    let bailian = RealtimeVoiceConfiguration(
        provider: .bailian,
        apiKey: "sk-bailian",
        agentID: nil,
        conversationToken: nil,
        voiceID: "Cherry",
        model: "qwen3-omni-flash-realtime",
        appID: nil,
        accessToken: nil,
        resourceID: nil
    )
    let elevenLabs = RealtimeVoiceConfiguration(
        provider: .elevenLabs,
        apiKey: nil,
        agentID: "agent_radio",
        conversationToken: nil,
        voiceID: nil,
        model: nil,
        appID: nil,
        accessToken: nil,
        resourceID: nil
    )
    let incompleteDoubao = RealtimeVoiceConfiguration(
        provider: .doubao,
        apiKey: nil,
        agentID: nil,
        conversationToken: nil,
        voiceID: nil,
        model: nil,
        appID: "rtc-app",
        accessToken: nil,
        resourceID: "resource"
    )

    #expect(bailian.isReadyToConnect)
    #expect(elevenLabs.isReadyToConnect)
    #expect(!incompleteDoubao.isReadyToConnect)
}

@Test
func connectedVoiceStateCanFinishAnInFlightConnectionAttempt() {
    #expect(
        RealtimeVoiceConnectionState.connecting
            .canCompleteConnectionAttempt
    )
    #expect(
        RealtimeVoiceConnectionState.connected
            .canCompleteConnectionAttempt
    )
    #expect(
        RealtimeVoiceConnectionState.listening
            .canCompleteConnectionAttempt
    )
    #expect(
        !RealtimeVoiceConnectionState.disconnected
            .canCompleteConnectionAttempt
    )
}

@MainActor
private final class CodexAccountServiceStub: CodexAccountServicing {
    var state: CodexAccountState
    var loginCount = 0
    var logoutCount = 0

    init(state: CodexAccountState) {
        self.state = state
    }

    func status() async -> CodexAccountState {
        state
    }

    func login() async throws {
        loginCount += 1
        state = .signedIn(method: "ChatGPT")
    }

    func logout() async throws {
        logoutCount += 1
        state = .signedOut
    }
}
