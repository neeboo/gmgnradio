import Foundation
import Testing
@testable import GMGNRadio

@MainActor
@Test
func agentCapabilityManifestCoversEveryCoreRadioAction() {
    let names = Set(DJAgentCapabilityManifest.capabilities.map(\.name))

    #expect(names == [
        "read_radio_state",
        "read_current_track",
        "search_music",
        "play_program_track",
        "next_track",
        "previous_track",
        "pause_music",
        "resume_music",
        "replan_program",
        "activate_prepared_program",
        "insert_track",
        "set_visual_mood",
        "set_lyrics_mode",
        "set_spatial_environment",
        "move_spatial_camera",
    ])
    #expect(
        DJAgentCapabilityManifest.capabilities
            .first { $0.name == "read_radio_state" }?
            .requiresTakeover == false
    )
    #expect(
        DJAgentCapabilityManifest.capabilities
            .filter {
                !["read_radio_state", "read_current_track", "search_music"]
                    .contains($0.name)
            }
            .allSatisfy { $0.requiresTakeover }
    )
}

@MainActor
@Test
func agentCanSwitchSpatialRoomAndWeather() async {
    let actions = DJAgentRadioActionsSpy()
    let dispatcher = DJAgentToolDispatcher(
        takeoverEnabled: { true },
        actions: actions
    )

    let environmentResult = await dispatcher.handle(RealtimeDJToolCall(
        id: "spatial-environment-1",
        name: "set_spatial_environment",
        argumentsJSON: Data(
            #"{"scene":"cosy_wood_house","weather":"thunderstorm"}"#.utf8
        )
    ))
    let cameraResult = await dispatcher.handle(RealtimeDJToolCall(
        id: "spatial-camera-1",
        name: "move_spatial_camera",
        argumentsJSON: Data(
            #"{"direction":"forward","distance":3}"#.utf8
        )
    ))

    #expect(environmentResult.isError == false)
    #expect(cameraResult.isError == false)
    #expect(actions.calls == [
        .spatialEnvironment(
            scene: .cosyWoodHouse,
            weather: .thunderstorm,
        ),
        .spatialCamera(direction: .forward, distance: 3),
    ])
}

@MainActor
@Test
func currentTrackToolSamplesThePlaybackStateAtInvocationTime() async throws {
    let actions = DJAgentRadioActionsSpy()
    let dispatcher = DJAgentToolDispatcher(
        takeoverEnabled: { false },
        actions: actions
    )

    actions.currentTrack = DJAgentCurrentTrackSnapshot.fixture(
        id: "track-1",
        title: "First",
        position: 12,
        previousTrack: DJAgentPlaybackTrack(
            id: "track-0",
            title: "Previous",
            artist: "Previous Artist"
        ),
        nextTrack: DJAgentPlaybackTrack(
            id: "track-2",
            title: "Second",
            artist: "Second Artist"
        )
    )
    let firstResult = await dispatcher.handle(RealtimeDJToolCall(
        id: "current-track-1",
        name: "read_current_track",
        argumentsJSON: Data("{}".utf8)
    ))

    actions.currentTrack = DJAgentCurrentTrackSnapshot.fixture(
        id: "track-2",
        title: "Second",
        position: 3
    )
    let secondResult = await dispatcher.handle(RealtimeDJToolCall(
        id: "current-track-2",
        name: "read_current_track",
        argumentsJSON: Data("{}".utf8)
    ))

    let first = try JSONDecoder().decode(
        DJAgentToolResponse.self,
        from: firstResult.resultJSON
    )
    let second = try JSONDecoder().decode(
        DJAgentToolResponse.self,
        from: secondResult.resultJSON
    )

    #expect(first.currentTrack?.id == "track-1")
    #expect(first.currentTrack?.positionSeconds == 12)
    #expect(first.currentTrack?.previousTrack?.id == "track-0")
    #expect(first.currentTrack?.nextTrack?.id == "track-2")
    #expect(second.currentTrack?.id == "track-2")
    #expect(second.currentTrack?.positionSeconds == 3)
    #expect(actions.currentTrackReadCount == 2)
}

@Test
func directPlaybackIntentRecognizesCommandsButNotQuestionsOrNegation() {
    #expect(
        DJDirectPlaybackIntent.resolve("播放当前选中的歌曲")
            == .playCurrent
    )
    #expect(
        DJDirectPlaybackIntent.resolve("请继续播放")
            == .playCurrent
    )
    #expect(DJDirectPlaybackIntent.resolve("开始放歌") == .playCurrent)
    #expect(DJDirectPlaybackIntent.resolve("播放下一首") == .next)
    #expect(DJDirectPlaybackIntent.resolve("换一首") == .next)
    #expect(DJDirectPlaybackIntent.resolve("回到上一首") == .previous)
    #expect(DJDirectPlaybackIntent.resolve("暂停一下") == .pause)
    #expect(DJDirectPlaybackIntent.resolve("这首歌能播放吗") == nil)
    #expect(DJDirectPlaybackIntent.resolve("先不要播放") == nil)
    #expect(DJDirectPlaybackIntent.resolve("不要播放下一首") == nil)
    #expect(DJDirectPlaybackIntent.resolve("下一首是什么") == nil)
}

@Test
func directProgramIntentRecognizesReplanCommandsButNotQuestionsOrNegation() {
    #expect(
        DJDirectProgramIntent.resolve(
            "请重新生成一份歌单，按照现在的时间和我的状态重新编排。"
        )
            == .replan(
                instruction:
                    "请重新生成一份歌单，按照现在的时间和我的状态重新编排。"
            )
    )
    #expect(
        DJDirectProgramIntent.resolve("换个歌单，来点更有精神的")
            == .replan(instruction: "换个歌单，来点更有精神的")
    )
    #expect(
        DJDirectProgramIntent.resolve("给我生成一个 City Pop 的歌单")
            == .replan(instruction: "给我生成一个 City Pop 的歌单")
    )
    #expect(DJDirectProgramIntent.resolve("你会不会生成歌单") == nil)
    #expect(DJDirectProgramIntent.resolve("先不要重新生成歌单") == nil)
}

@Test
func directInsertIntentRecognizesInterludeRequestsButNotQuestionsOrNegation() {
    #expect(
        DJDirectInsertIntent.resolve("下一首插播一首陈奕迅")
            == .insert(instruction: "下一首插播一首陈奕迅")
    )
    #expect(
        DJDirectInsertIntent.resolve("等下放一首轻快的 City Pop")
            == .insert(instruction: "等下放一首轻快的 City Pop")
    )
    #expect(DJDirectInsertIntent.resolve("怎么插播歌曲") == nil)
    #expect(DJDirectInsertIntent.resolve("先不要插播") == nil)
}

@Test
func directProgramSwitchIntentRecognizesPreparedPlaylistConfirmation() {
    #expect(
        DJDirectProgramSwitchIntent.resolve("好，切过去吧")
            == .activatePrepared
    )
    #expect(
        DJDirectProgramSwitchIntent.resolve("直接播放新歌单")
            == .activatePrepared
    )
    #expect(
        DJDirectProgramSwitchIntent.resolve(
            "好的",
            hasPreparedProgram: true
        ) == .activatePrepared
    )
    #expect(
        DJDirectProgramSwitchIntent.resolve(
            "好的",
            hasPreparedProgram: false
        ) == nil
    )
    #expect(DJDirectProgramSwitchIntent.resolve("先别切过去") == nil)
    #expect(DJDirectProgramSwitchIntent.resolve("切过去会怎样") == nil)
}

@MainActor
@Test
func agentCanActivateThePreparedProgramAfterConfirmation() async {
    let actions = DJAgentRadioActionsSpy()
    let dispatcher = DJAgentToolDispatcher(
        takeoverEnabled: { true },
        actions: actions
    )

    let result = await dispatcher.handle(RealtimeDJToolCall(
        id: "activate-1",
        name: "activate_prepared_program",
        argumentsJSON: Data("{}".utf8)
    ))

    #expect(result.isError == false)
    #expect(actions.calls == [.activatePrepared])
}

@MainActor
@Test
func agentCanSearchConnectedMusicCatalogWithoutTakingControl()
    async throws
{
    let actions = DJAgentRadioActionsSpy()
    let dispatcher = DJAgentToolDispatcher(
        takeoverEnabled: { false },
        actions: actions
    )
    let arguments = Data(
        #"{"query":"深夜爵士","limit":5}"#.utf8
    )

    let result = await dispatcher.handle(RealtimeDJToolCall(
        id: "search-1",
        name: "search_music",
        argumentsJSON: arguments
    ))
    let body = try JSONDecoder().decode(
        DJAgentToolResponse.self,
        from: result.resultJSON
    )

    #expect(result.isError == false)
    #expect(actions.calls == [.search(query: "深夜爵士", limit: 5)])
    #expect(body.tracks?.map(\.id) == ["result-1"])
}

@MainActor
@Test
func agentCanSelectTheLyricsPresentationMode() async throws {
    let actions = DJAgentRadioActionsSpy()
    let dispatcher = DJAgentToolDispatcher(
        takeoverEnabled: { true },
        actions: actions
    )
    let arguments = try JSONEncoder().encode([
        "mode": "orbit_arc",
    ])

    let result = await dispatcher.handle(RealtimeDJToolCall(
        id: "lyrics-1",
        name: "set_lyrics_mode",
        argumentsJSON: arguments
    ))

    #expect(result.isError == false)
    #expect(actions.calls == [.lyrics(.orbitArc)])
}

@MainActor
@Test
func agentCanInsertAnInterludeFromNaturalLanguage() async throws {
    let actions = DJAgentRadioActionsSpy()
    let dispatcher = DJAgentToolDispatcher(
        takeoverEnabled: { true },
        actions: actions
    )
    let arguments = try JSONEncoder().encode([
        "immediate_instruction": "下一首插播一首轻快的陈奕迅",
    ])

    let result = await dispatcher.handle(RealtimeDJToolCall(
        id: "insert-1",
        name: "insert_track",
        argumentsJSON: arguments
    ))
    let body = try JSONDecoder().decode(
        DJAgentToolResponse.self,
        from: result.resultJSON
    )

    #expect(result.isError == false)
    #expect(actions.calls == [
        .insert("下一首插播一首轻快的陈奕迅"),
    ])
    #expect(body.message.contains("后台"))
    #expect(body.message.contains("找歌"))
    #expect(!body.message.contains("已按要求安排"))
}

@MainActor
@Test
func agentCanReadRadioStateWithoutTakingControl() async throws {
    let actions = DJAgentRadioActionsSpy()
    let dispatcher = DJAgentToolDispatcher(
        takeoverEnabled: { false },
        actions: actions
    )

    let result = await dispatcher.handle(RealtimeDJToolCall(
        id: "read-1",
        name: "read_radio_state",
        argumentsJSON: Data("{}".utf8)
    ))
    let body = try JSONDecoder().decode(
        DJAgentToolResponse.self,
        from: result.resultJSON
    )

    #expect(result.isError == false)
    #expect(body.ok)
    #expect(body.state?.activeTrackID == "track-1")
    #expect(actions.calls.isEmpty)
}

@MainActor
@Test
func agentMutationIsRejectedUntilTakeoverIsEnabled() async throws {
    let actions = DJAgentRadioActionsSpy()
    let dispatcher = DJAgentToolDispatcher(
        takeoverEnabled: { false },
        actions: actions
    )

    let result = await dispatcher.handle(RealtimeDJToolCall(
        id: "next-1",
        name: "next_track",
        argumentsJSON: Data("{}".utf8)
    ))
    let body = try JSONDecoder().decode(
        DJAgentToolResponse.self,
        from: result.resultJSON
    )

    #expect(result.isError)
    #expect(body.code == "takeover_disabled")
    #expect(actions.calls.isEmpty)
}

@MainActor
@Test
func agentPlayToolRoutesByTrackIDAndReturnsTheUpdatedState() async throws {
    let actions = DJAgentRadioActionsSpy()
    let dispatcher = DJAgentToolDispatcher(
        takeoverEnabled: { true },
        actions: actions
    )
    let arguments = try JSONEncoder().encode([
        "track_id": "track-2",
    ])

    let result = await dispatcher.handle(RealtimeDJToolCall(
        id: "play-1",
        name: "play_program_track",
        argumentsJSON: arguments
    ))
    let body = try JSONDecoder().decode(
        DJAgentToolResponse.self,
        from: result.resultJSON
    )

    #expect(result.isError == false)
    #expect(actions.calls == [.play(trackID: "track-2", slotIndex: nil)])
    #expect(body.state?.activeTrackID == "track-2")
}

@MainActor
@Test
func duplicateAgentToolCallIsExecutedOnlyOnce() async {
    let actions = DJAgentRadioActionsSpy()
    let dispatcher = DJAgentToolDispatcher(
        takeoverEnabled: { true },
        actions: actions
    )
    let call = RealtimeDJToolCall(
        id: "skip-once",
        name: "next_track",
        argumentsJSON: Data("{}".utf8)
    )

    let first = await dispatcher.handle(call)
    let replay = await dispatcher.handle(call)

    #expect(first == replay)
    #expect(actions.calls == [.next])
}

@MainActor
@Test
func newAgentSessionCanReuseAnOldProviderCallID() async {
    let actions = DJAgentRadioActionsSpy()
    let dispatcher = DJAgentToolDispatcher(
        takeoverEnabled: { true },
        actions: actions
    )
    let call = RealtimeDJToolCall(
        id: "provider-call-1",
        name: "next_track",
        argumentsJSON: Data("{}".utf8)
    )

    _ = await dispatcher.handle(call)
    dispatcher.resetSession()
    _ = await dispatcher.handle(call)

    #expect(actions.calls == [.next, .next])
}

@MainActor
private final class DJAgentRadioActionsSpy: DJAgentRadioActions {
    enum Call: Equatable {
        case play(trackID: String?, slotIndex: Int?)
        case next
        case previous
        case pause
        case resume
        case replan(String?)
        case activatePrepared
        case insert(String)
        case visual(StageVisualMood)
        case search(query: String, limit: Int)
        case lyrics(StageLyricsVisualMode)
        case spatialEnvironment(
            scene: SpatialScenePreset?,
            weather: SpatialWeather?
        )
        case spatialCamera(
            direction: SpatialCameraCommandDirection,
            distance: Float
        )
    }

    var calls: [Call] = []
    private var activeTrackID = "track-1"
    var currentTrack = DJAgentCurrentTrackSnapshot.fixture(
        id: "track-1",
        title: "First",
        position: 12
    )
    private(set) var currentTrackReadCount = 0

    func snapshot(takeoverEnabled: Bool) -> DJAgentRadioState {
        DJAgentRadioState(
            takeoverEnabled: takeoverEnabled,
            playbackState: "playing",
            activeTrackID: activeTrackID,
            activeSlotIndex: activeTrackID == "track-2" ? 1 : 0,
            program: [
                DJAgentProgramTrack(
                    index: 0,
                    id: "track-1",
                    title: "First",
                    artist: "Artist One"
                ),
                DJAgentProgramTrack(
                    index: 1,
                    id: "track-2",
                    title: "Second",
                    artist: "Artist Two"
                ),
            ]
        )
    }

    func currentTrackSnapshot() -> DJAgentCurrentTrackSnapshot? {
        currentTrackReadCount += 1
        return currentTrack
    }

    func playProgramTrack(
        trackID: String?,
        slotIndex: Int?
    ) async throws {
        calls.append(.play(trackID: trackID, slotIndex: slotIndex))
        if let trackID {
            activeTrackID = trackID
        }
    }

    func playNextTrack() async throws {
        calls.append(.next)
    }

    func playPreviousTrack() async throws {
        calls.append(.previous)
    }

    func pauseMusic() async throws {
        calls.append(.pause)
    }

    func resumeMusic() async throws {
        calls.append(.resume)
    }

    func replanProgram(immediateInstruction: String?) async throws {
        calls.append(.replan(immediateInstruction))
    }

    func activatePreparedProgram() async throws {
        calls.append(.activatePrepared)
    }

    func insertTrack(immediateInstruction: String) async throws {
        calls.append(.insert(immediateInstruction))
    }

    func setVisualMood(_ mood: StageVisualMood) async throws {
        calls.append(.visual(mood))
    }

    func searchMusic(
        query: String,
        limit: Int
    ) async throws -> [DJAgentMusicTrack] {
        calls.append(.search(query: query, limit: limit))
        return [
            DJAgentMusicTrack(
                id: "result-1",
                provider: "netease",
                title: "Night",
                artist: "Artist",
                album: "Album",
                duration: 180,
                isPlayable: true
            ),
        ]
    }

    func setLyricsMode(
        _ mode: StageLyricsVisualMode
    ) async throws {
        calls.append(.lyrics(mode))
    }

    func setSpatialEnvironment(
        scene: SpatialScenePreset?,
        weather: SpatialWeather?
    ) async throws {
        calls.append(.spatialEnvironment(
            scene: scene,
            weather: weather
        ))
    }

    func moveSpatialCamera(
        direction: SpatialCameraCommandDirection,
        distance: Float
    ) async throws {
        calls.append(.spatialCamera(
            direction: direction,
            distance: distance
        ))
    }
}

private extension DJAgentCurrentTrackSnapshot {
    static func fixture(
        id: String,
        title: String,
        position: TimeInterval,
        previousTrack: DJAgentPlaybackTrack? = nil,
        nextTrack: DJAgentPlaybackTrack? = nil
    ) -> Self {
        Self(
            sampledAt: "2026-08-02T06:30:00Z",
            playbackState: "playing",
            isPlaying: true,
            id: id,
            provider: "netease",
            source: "streaming",
            title: title,
            artist: "Artist",
            album: "Album",
            durationSeconds: 180,
            positionSeconds: position,
            remainingSeconds: 180 - position,
            progress: position / 180,
            programID: "program-1",
            programTitle: "Program",
            slotIndex: id == "track-1" ? 0 : 1,
            previousTrack: previousTrack,
            nextTrack: nextTrack
        )
    }
}
