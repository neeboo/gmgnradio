import Foundation
import Testing
@testable import GMGNRadio

@Test
@MainActor
func presentationModelSelectsTheCueForTheCurrentProgramTime() {
    let model = StagePresentationModel(
        programTitle: "MIDNIGHT DRIVE",
        programDetail: "DJ 自主节目"
    )
    let cues = [
        StageTextCue(
            text: "第一段主持词",
            secondaryText: "介绍上一首歌",
            startsAt: 0,
            endsAt: 8
        ),
        StageTextCue(
            text: "第二段主持词",
            secondaryText: "串到下一首歌",
            startsAt: 8,
            endsAt: 15
        )
    ]

    model.update(cues: cues, at: 10)

    #expect(model.programTitle == "MIDNIGHT DRIVE")
    #expect(model.currentCue?.text == "第二段主持词")

    model.update(cues: cues, at: 16)

    #expect(model.currentCue == nil)
}

@Test
func textCueUsesAHalfOpenTimeRange() {
    let cue = StageTextCue(
        text: "串歌",
        secondaryText: nil,
        startsAt: 2,
        endsAt: 5
    )

    #expect(!cue.isActive(at: 1.99))
    #expect(cue.isActive(at: 2))
    #expect(cue.isActive(at: 4.99))
    #expect(!cue.isActive(at: 5))
}

@Test
@MainActor
func presentationModelConsumesProgramContextAndLiveDJTranscript() {
    let model = StagePresentationModel()
    let currentTrack = TrackReference(
        id: "track-1",
        title: "Midnight City",
        artist: "M83"
    )
    let nextTrack = TrackReference(
        id: "track-2",
        title: "Intro",
        artist: "The xx"
    )
    let context = RealtimeDJContext(
        playback: PlaybackContext(currentTrack: currentTrack),
        showPlanSummary: "NIGHT DRIVE",
        hostHint: ProgramHostHint(
            shouldTalkBefore: true,
            maxSentenceCount: 2,
            selectionReason: "这首歌适合现在的夜路。",
            currentTrack: currentTrack,
            nextTrack: nextTrack,
            facts: [],
            transitionIntent: "下一首会更安静一些。"
        )
    )

    model.apply(context)

    #expect(model.programTitle == "NIGHT DRIVE")
    #expect(model.programDetail == "Midnight City — M83")
    #expect(model.currentCue == nil)

    model.consume(.agentResponseStarted)
    model.consume(.agentTranscriptDelta("今晚"))
    model.consume(.agentTranscriptDelta("慢一点。"))

    #expect(model.currentCue?.text == "今晚慢一点。")
    #expect(model.currentCue?.emphasis == 1)

    model.apply(
        RealtimeDJContext(
            playback: PlaybackContext(currentTrack: nextTrack),
            showPlanSummary: "NIGHT DRIVE"
        )
    )

    #expect(model.currentCue == nil)
}

@Test
@MainActor
func longDJTranscriptIsPagedInsteadOfBeingClipped() {
    let text = "正在播放 Paul Desmond 的《A Garden in the Rain》，接下来是 Radiohead 的《15 Step》。继续这档日光流线节目，让音乐自己往前走。"
    let pages = StageDJCaptionFormatter.pages(
        for: text,
        maxCharacters: 32
    )
    let model = StagePresentationModel()

    model.consume(.agentTranscriptFinal(text))

    #expect(pages.count >= 3)
    #expect(pages.allSatisfy { $0.count <= 32 })
    #expect(pages.joined() == text)
    #expect(
        model.currentCue?.text
            == pages.last
    )
}

@Test
@MainActor
func liveDJCaptionDisappearsWhenSpokenAudioFinishes() {
    let model = StagePresentationModel()

    model.consume(.agentResponseStarted)
    model.consume(.agentAudioStarted)
    model.consume(.agentTranscriptDelta("City Pop 歌单已经准备好了。"))
    #expect(model.currentCue != nil)

    model.consume(.agentAudioFinished)
    #expect(model.currentCue == nil)

    model.consume(.agentTranscriptFinal("迟到的最终转写不应重新出现。"))
    #expect(model.currentCue == nil)
}

@Test
func liveDJCaptionKeepsTheLatestThreePagesVisible() {
    let text = "第一段主持内容会先出现，第二段接着介绍歌曲，第三段继续讲一点背景，第四段负责自然地带到下一首歌。"
    let pages = StageDJCaptionFormatter.pages(
        for: text,
        maxCharacters: 16
    )
    let window = StageDJCaptionFormatter.visibleWindow(
        for: text,
        maxCharacters: 16,
        maximumPages: 3
    )

    #expect(window?.text == pages.suffix(3).joined(separator: "\n"))
    #expect((window?.text.split(separator: "\n").count ?? 0) <= 3)
}

@Test
func lrcParserExpandsSharedTextTimestampsAndSortsTheTimeline() {
    let lines = LRCParser().parse(
        """
        [ar:Example]
        [00:12.50][00:18.00]同一句
        [00:08.20]先出现
        [00:24.00]最后一句
        """
    )

    #expect(lines.map(\.text) == ["先出现", "同一句", "同一句", "最后一句"])
    #expect(lines.map(\.startsAt) == [8.2, 12.5, 18, 24])
}

@Test
func yrcParserPreservesLineAndWordTimingsWithTranslation() throws {
    let lines = YRCParser().parse(
        """
        [8200,4000](8200,800,0)今(9000,700,0)晚(9700,900,0)慢(10600,700,0)一(11300,900,0)点
        """,
        translation: "[00:08.20]Slow down tonight"
    )

    let line = try #require(lines.first)
    #expect(line.startsAt == 8.2)
    #expect(line.endsAt == 12.2)
    #expect(line.text == "今晚慢一点")
    #expect(line.translation == "Slow down tonight")
    #expect(line.words.map(\.text) == ["今", "晚", "慢", "一", "点"])
    #expect(line.words.map(\.startsAt) == [8.2, 9, 9.7, 10.6, 11.3])
    #expect(line.words.map(\.endsAt) == [9, 9.7, 10.6, 11.3, 12.2])
}

@Test
func lrcParserSynthesizesGraphemeTimingAndAlignsTranslation() throws {
    let lines = LRCParser().parse(
        """
        [00:08.20]今晚，慢一点
        [00:12.50]下一首
        """,
        translation: """
        [00:08.20]Slow down tonight
        [00:12.50]Next song
        """
    )

    let first = try #require(lines.first)
    #expect(first.endsAt == 12.5)
    #expect(first.translation == "Slow down tonight")
    #expect(first.words.map(\.text).joined() == "今晚，慢一点")
    #expect(first.words.first?.startsAt == 8.2)
    #expect(first.words.last?.endsAt == 12.5)
    #expect(first.words.allSatisfy { $0.endsAt > $0.startsAt })
}

@Test
func lrcParserKeepsTheFinalLineUntilTheKnownTrackEnd() throws {
    let lines = LRCParser().parse(
        "[02:50.00]最后一句",
        trackDuration: 180
    )

    let line = try #require(lines.first)
    #expect(line.endsAt == 180)
    #expect(line.words.last?.endsAt == 180)
}

@Test
func flowingLyricTypographyFitsLongLinesToTheStageWidth() {
    let fontSize = StageLyricTypography.fontSize(
        text: String(repeating: "长", count: 40),
        availableWidth: 1_180
    )

    #expect(fontSize < 30)
}

@Test
func flowingLyricRenderPolicyUsesDisplayCadenceAndOneDynamicGlow() {
    #expect(StageLyricRenderPolicy.minimumFrameInterval == 1.0 / 60.0)
    #expect(
        StageLyricRenderPolicy.shouldRenderDynamicGlow(for: .waiting)
            == false
    )
    #expect(
        StageLyricRenderPolicy.shouldRenderDynamicGlow(for: .active)
            == true
    )
    #expect(
        StageLyricRenderPolicy.shouldRenderDynamicGlow(for: .passed)
            == false
    )
}

@Test
func flowSceneDrivesEveryGraphemeThroughWaitingActiveAndPassed() throws {
    let line = StageLyricLine(
        id: "line",
        startsAt: 8,
        endsAt: 11,
        text: "慢一点",
        translation: "Take it slow",
        words: [
            StageLyricWord(id: "slow", startsAt: 8, endsAt: 9.5, text: "慢"),
            StageLyricWord(id: "a-little", startsAt: 9.5, endsAt: 11, text: "一点"),
        ]
    )

    let scene = StageLyricFlowSceneModel(lines: [line], playbackTime: 10)

    #expect(scene.activeLine?.text == "慢一点")
    #expect(scene.translation == "Take it slow")
    #expect(scene.glyphs.map(\.text) == ["慢", "一", "点"])
    #expect(scene.glyphs.map(\.phase) == [.passed, .active, .waiting])
    #expect(scene.glyphs[1].progress > 0)
    #expect(scene.glyphs[1].progress < 1)
}

@Test
func flowSceneKeepsEnglishWordsWholeAndSplitsChineseCharacters() {
    let line = StageLyricLine(
        id: "mixed",
        startsAt: 8,
        endsAt: 12,
        text: "Hold on 今晚",
        words: [
            StageLyricWord(
                id: "hold",
                startsAt: 8,
                endsAt: 9,
                text: "Hold "
            ),
            StageLyricWord(
                id: "on",
                startsAt: 9,
                endsAt: 10,
                text: "on "
            ),
            StageLyricWord(
                id: "tonight",
                startsAt: 10,
                endsAt: 12,
                text: "今晚"
            ),
        ]
    )

    let scene = StageLyricFlowSceneModel(
        lines: [line],
        playbackTime: 10.5
    )

    #expect(scene.glyphs.map(\.text) == ["Hold ", "on ", "今", "晚"])
}

@Test
func flowSceneCarriesNeighboringLinesAndDetectsRepeatedChorus() {
    let lines = [
        StageLyricLine(
            id: "verse",
            startsAt: 0,
            endsAt: 4,
            text: "街灯慢慢向后退"
        ),
        StageLyricLine(
            id: "chorus-a",
            startsAt: 4,
            endsAt: 8,
            text: "今夜不要停下来"
        ),
        StageLyricLine(
            id: "bridge",
            startsAt: 8,
            endsAt: 12,
            text: "让霓虹落进海里"
        ),
        StageLyricLine(
            id: "chorus-b",
            startsAt: 12,
            endsAt: 16,
            text: "今夜不要停下来"
        ),
    ]

    let scene = StageLyricFlowSceneModel(
        lines: lines,
        playbackTime: 5
    )

    #expect(scene.previousLine?.text == "街灯慢慢向后退")
    #expect(scene.nextLine?.text == "让霓虹落进海里")
    #expect(scene.isChorus)
}

@Test
func flowSceneKeepsTheLastSungLineVisibleAcrossAnInstrumentalGap() throws {
    let lines = [
        StageLyricLine(
            id: "sung",
            startsAt: 4,
            endsAt: 7,
            text: "让余韵留在这里"
        ),
        StageLyricLine(
            id: "next",
            startsAt: 13,
            endsAt: 17,
            text: "下一句还没有开始"
        ),
    ]

    let scene = StageLyricFlowSceneModel(
        lines: lines,
        playbackTime: 10
    )

    #expect(scene.activeLine?.id == "sung")
    #expect(scene.nextLine?.id == "next")
    #expect(scene.lineProgress == 1)
    #expect(scene.glyphs.allSatisfy { $0.phase == .passed })
}

@Test
func lrcParserSynthesizesEnglishWordAndChineseCharacterTiming() throws {
    let lines = LRCParser().parse(
        """
        [00:01.00]Hold on, 今晚
        [00:05.00]下一句
        """
    )

    let first = try #require(lines.first)
    #expect(first.words.map(\.text) == ["Hold ", "on, ", "今", "晚"])
    #expect(first.words.first?.startsAt == 1)
    #expect(first.words.last?.endsAt == 5)
}

@Test
func lyricSceneKeepsTheCurrentLineClearAndNeighborsInDepth() {
    let scene = StageLyricSceneModel(
        lines: [
            StageLyricLine(startsAt: 4, text: "上一句"),
            StageLyricLine(startsAt: 8, text: "这一句"),
            StageLyricLine(startsAt: 12, text: "下一句"),
            StageLyricLine(startsAt: 16, text: "更远一句"),
        ],
        playbackTime: 10
    )

    #expect(scene.lines.map(\.text) == ["上一句", "这一句", "下一句"])
    #expect(scene.lines.map(\.position) == [-1, 0, 1])
    #expect(scene.lines[1].opacity == 1)
    #expect(scene.lines[1].blurRadius == 0)
    #expect(scene.lines[0].opacity < scene.lines[1].opacity)
    #expect(scene.lines[2].depth < scene.lines[1].depth)
}

@Test
func automaticLyricDirectorKeepsOneThemeForTheWholeTrack() {
    let lines = (0 ..< 16).map { index in
        StageLyricLine(
            id: "line-\(index)",
            startsAt: TimeInterval(index * 4),
            endsAt: TimeInterval((index + 1) * 4),
            text: "第 \(index) 句"
        )
    }
    let modes = [1.0, 17.0, 33.0, 49.0].map { time in
        StageLyricModeDirector.resolve(
            configuredMode: .automatic,
            trackID: "night-radio",
            lines: lines,
            playbackTime: time
        )
    }

    #expect(Set(modes).count == 1)
    #expect(!modes.contains(.automatic))
}

@Test
func lyricThemeContractIncludesAllTenFoliaCompositions() {
    #expect(
        StageLyricsVisualMode.playbackModes.map(\.agentValue) == [
            "luminous",
            "mindscape",
            "cloud_steps",
            "article",
            "chorus_chat",
            "confession",
            "claddagh",
            "monet_poster",
            "pendulum",
            "diorama",
        ]
    )
    #expect(StageLyricsVisualMode.agentValues.count == 11)
}

@Test
func lyricAudioMotionUsesRealBandsAndBeat() {
    let quiet = StageLyricAudioMotion(
        features: .silent,
        animationTime: 2
    )
    let musical = StageLyricAudioMotion(
        features: VisualAudioFeatures(
            low: 0.8,
            mid: 0.6,
            high: 0.4,
            beat: 0.9,
            onset: 0.7,
            amplitude: 0.75
        ),
        animationTime: 2
    )

    #expect(quiet.expansion == 1)
    #expect(musical.expansion == 1)
    #expect(quiet.beatLift == 0)
    #expect(musical.beatLift == 0)
    #expect(musical.glow > quiet.glow)
    #expect(musical.particleEnergy > quiet.particleEnergy)
}
