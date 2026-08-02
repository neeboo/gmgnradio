import Foundation
import Testing
@testable import GMGNRadio

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
    let suiteName = "AgentSettingsModelTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = AgentSettingsModel(
        account: account,
        preferences: DJAgentPreferences(defaults: defaults)
    )

    await model.load()
    model.hostPrompt = "少说一点，多留意时间和用户刚才说的话。"
    model.savePrompt()

    #expect(model.codexState == .signedIn(method: "ChatGPT"))
    #expect(
        defaults.string(forKey: DJAgentPreferences.hostPromptKey)
            == "少说一点，多留意时间和用户刚才说的话。"
    )
}

@MainActor
@Test
func agentSettingsPersistsTakeoverAndPlanningModel() throws {
    let suiteName = "AgentControlSettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = DJAgentPreferences(defaults: defaults)
    let model = AgentSettingsModel(preferences: preferences)

    model.takeoverEnabled = true
    model.planningModel = "gpt-5.4"
    model.saveAgentConfiguration()

    let reloaded = AgentSettingsModel(preferences: preferences)
    #expect(reloaded.takeoverEnabled)
    #expect(reloaded.planningModel == "gpt-5.4")
}

@MainActor
@Test
func agentSettingsStartsCodexLoginAndRefreshesTheState() async {
    let account = CodexAccountServiceStub(state: .signedOut)
    let model = AgentSettingsModel(account: account)

    await model.connectCodex()

    #expect(account.loginCount == 1)
    #expect(model.codexState == .signedIn(method: "ChatGPT"))
}

@MainActor
@Test
func agentSettingsLogsOutOfCodexAndReturnsToSignedOut() async {
    let account = CodexAccountServiceStub(
        state: .signedIn(method: "ChatGPT")
    )
    let model = AgentSettingsModel(account: account)

    await model.disconnectCodex()

    #expect(account.logoutCount == 1)
    #expect(model.codexState == .signedOut)
}

@MainActor
@Test
func agentSettingsPersistsRealtimeVoiceWithoutPuttingTokenInDefaults()
    throws
{
    let suiteName = "RealtimeVoiceSettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let secrets = RealtimeVoiceSecretStoreStub()
    let voicePreferences = RealtimeVoicePreferences(
        defaults: defaults,
        secrets: secrets
    )
    let model = AgentSettingsModel(
        preferences: DJAgentPreferences(defaults: defaults),
        voicePreferences: voicePreferences
    )
    model.elevenLabsAgentID = "agent_radio"
    model.elevenLabsVoiceID = "voice-night"
    model.elevenLabsConversationToken = "private-token"
    model.voiceAPIKey = "sk-elevenlabs"

    let configuration = try #require(model.saveVoiceConfiguration())

    #expect(configuration.agentID == "agent_radio")
    #expect(configuration.voiceID == "voice-night")
    #expect(configuration.conversationToken == "private-token")
    #expect(configuration.apiKey == "sk-elevenlabs")
    #expect(
        defaults.string(
            forKey: RealtimeVoicePreferences.conversationTokenKey
        ) == nil
    )
    #expect(
        secrets.values[RealtimeVoicePreferences.conversationTokenKey]
            == "private-token"
    )
    #expect(
        secrets.values[RealtimeVoicePreferences.apiKeyKey]
            == "sk-elevenlabs"
    )
}

@MainActor
@Test
func realtimeVoiceConfigurationAcceptsPublicAgentWithoutPrivateToken() {
    let model = AgentSettingsModel()
    model.elevenLabsAgentID = "agent_public"
    model.elevenLabsConversationToken = ""

    let configuration = model.saveVoiceConfiguration()

    #expect(configuration?.agentID == "agent_public")
    #expect(configuration?.conversationToken == nil)
}

@MainActor
@Test
func realtimeVoiceConfigurationRejectsThePlaceholderAgentID() {
    let model = AgentSettingsModel()
    model.selectRealtimeProvider(.elevenLabs)
    model.elevenLabsAgentID = "agent-public"

    let configuration = model.saveVoiceConfiguration()

    #expect(configuration == nil)
    #expect(model.hasError)
    #expect(model.message?.contains("真实") == true)
}

@MainActor
@Test
func agentSettingsSwitchesProviderAndStoresBailianKeyInKeychain()
    throws
{
    let suiteName = "RealtimeVoiceProviderTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let secrets = RealtimeVoiceSecretStoreStub()
    let preferences = RealtimeVoicePreferences(
        defaults: defaults,
        secrets: secrets
    )
    let model = AgentSettingsModel(voicePreferences: preferences)

    model.selectRealtimeProvider(.bailian)
    model.voiceAPIKey = "sk-bailian"

    let configuration = try #require(model.saveVoiceConfiguration())

    #expect(configuration.provider == .bailian)
    #expect(configuration.apiKey == "sk-bailian")
    #expect(configuration.model == BailianRealtimeOptions.defaultModel)
    #expect(configuration.voiceID == BailianRealtimeOptions.defaultVoice)
    #expect(defaults.string(forKey: "voice.bailian.apiKey") == nil)
    #expect(secrets.values["voice.bailian.apiKey"] == "sk-bailian")
}

@MainActor
@Test
func bailianModelAndVoiceUseSelectableDefaults() {
    let model = AgentSettingsModel()

    model.selectRealtimeProvider(.bailian)

    #expect(
        BailianRealtimeOptions.models.contains {
            $0.id == model.voiceModel
        }
    )
    #expect(
        BailianRealtimeOptions.voices(
            for: model.voiceModel
        ).contains {
            $0.id == model.voiceID
        }
    )
}

@Test
func realtimeVoiceKeychainUsesTheStableSignatureNamespace() {
    #expect(
        KeychainRealtimeVoiceSecretStore.defaultService
            == "ai.gmgn.radio.voice.stable-v1"
    )
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

private final class RealtimeVoiceSecretStoreStub:
    RealtimeVoiceSecretStoring
{
    var values: [String: String] = [:]

    func string(forKey key: String) -> String? {
        values[key]
    }

    func setString(_ value: String?, forKey key: String) throws {
        values[key] = value
    }
}
