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
    #expect(model.currentCue?.text == "这首歌适合现在的夜路。")

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
