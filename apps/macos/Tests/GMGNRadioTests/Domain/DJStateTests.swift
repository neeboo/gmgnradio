import Testing
@testable import GMGNRadio

@Test
func speakingThenMusicReturnsToPlaying() {
    var machine = DJStateMachine(initial: .playing)

    machine.handle(.agentSpeechStarted)
    #expect(machine.state == .speaking)

    machine.handle(.agentSpeechFinished)
    #expect(machine.state == .playing)
}

@Test
func userCanInterruptAgentSpeech() {
    var machine = DJStateMachine(initial: .playing)
    machine.handle(.agentSpeechStarted)

    machine.handle(.userSpeechStarted)
    #expect(machine.state == .listening)

    machine.handle(.userSpeechFinished)
    #expect(machine.state == .thinking)
}

@Test
func reconnectingReturnsToPreviousProgramState() {
    var machine = DJStateMachine(initial: .playing)

    machine.handle(.connectionLost)
    #expect(machine.state == .reconnecting)

    machine.handle(.connectionRestored)
    #expect(machine.state == .playing)
}

@Test
func privacyOffRequiresExplicitReenable() {
    var machine = DJStateMachine(initial: .listening)

    machine.handle(.privacyDisabled)
    machine.handle(.userSpeechStarted)
    #expect(machine.state == .privacyOff)

    machine.handle(.privacyEnabled)
    #expect(machine.state == .idle)
}

@Test
func orbPresentationFollowsDJState() {
    #expect(OrbState(djState: .dormant) == .hidden)
    #expect(OrbState(djState: .listening) == .receptive)
    #expect(OrbState(djState: .playing) == .musical)
    #expect(OrbState(djState: .failed) == .error)
}

@Test
func programDecisionKeepsItsIdempotencyKey() {
    let decision = ProgramDecision(
        id: "decision-1",
        idempotencyKey: "program-7:queue-2",
        action: .replaceUpcomingQueue(trackIDs: ["track-a", "track-b"]),
        rationale: "Keep the late-night set calm."
    )

    #expect(decision.idempotencyKey == "program-7:queue-2")
    #expect(decision.action == .replaceUpcomingQueue(trackIDs: ["track-a", "track-b"]))
}

@Test
func playbackContextStartsQuietAndConversational() {
    let context = PlaybackContext()

    #expect(context.currentTrack == nil)
    #expect(context.upcomingTrackIDs.isEmpty)
    #expect(context.musicGain == 1)
    #expect(context.conversationMode == .ambient)
}
