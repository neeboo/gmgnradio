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
