import Foundation
import Testing
@testable import GMGNRadio

@Test
func openingTheMicrophoneDoesNotCreateAPlaybackEngine() {
    #expect(
        RealtimeVoicePlaybackAudioRoute.resolve(
            hasExistingPlaybackAudio: false
        ) == .connectWithoutPlaybackAudio
    )
    #expect(
        RealtimeVoicePlaybackAudioRoute.resolve(
            hasExistingPlaybackAudio: true
        ) == .reuseExistingPlaybackAudio
    )
}

@Test
func realtimeVoiceConnectionHasAFiniteDeadline() async {
    await #expect(throws: RealtimeVoiceConnectionError.timedOut) {
        try await RealtimeVoiceConnectionDeadline(
            duration: .milliseconds(1)
        ).wait()
    }
}

@Test
func providersExposeTheirVerifiedRealtimeCapabilities() {
    let bailian = RealtimeDJProvider.bailian.capabilities
    let doubao = RealtimeDJProvider.doubao.capabilities
    let elevenLabs = RealtimeDJProvider.elevenLabs.capabilities

    #expect(bailian.transport == .streamingWebSocket)
    #expect(bailian.serverVoiceActivityDetection)
    #expect(bailian.liveContextUpdates)
    #expect(bailian.clientTools)

    #expect(doubao.transport == .rtcRoom)
    #expect(doubao.serverVoiceActivityDetection)
    #expect(doubao.nativeInterruption)
    #expect(doubao.clientTools)

    #expect(elevenLabs.transport == .webRTC)
    #expect(elevenLabs.serverVoiceActivityDetection)
    #expect(elevenLabs.nativeInterruption)
    #expect(elevenLabs.liveContextUpdates)
    #expect(elevenLabs.clientTools)
    #expect(elevenLabs.independentMicrophoneCaptureAndTransmission == false)
    #expect(RealtimeDJProvider.elevenLabs.rawValue == "elevenlabs")
}

@Test
func sessionTicketKeepsProviderCredentialsOpaqueToTheApplication() {
    let payload = Data(#"{"roomId":"room-1","token":"short-lived"}"#.utf8)
    let ticket = RealtimeDJSessionTicket(
        provider: .doubao,
        sessionID: "radio-session-1",
        expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
        providerPayload: payload
    )

    #expect(ticket.provider == .doubao)
    #expect(ticket.sessionID == "radio-session-1")
    #expect(ticket.providerPayload == payload)
}

@Test
func realtimeContextCarriesTheHostBriefWithoutProviderFields() {
    let context = RealtimeDJContext(
        playback: PlaybackContext(
            currentTrack: TrackReference(
                id: "track-current",
                title: "Blue Hour",
                artist: "Example Artist"
            ),
            upcomingTrackIDs: ["track-next"],
            musicGain: 0.72,
            conversationMode: .quiet,
            programID: "late-night-1"
        ),
        showPlanSummary: "深夜工作时段，保持克制，只在必要转场出现。",
        hostPreference: "关键转场再说话，介绍必须基于歌曲事实。",
        immediateUserInstruction: "少说一点"
    )

    #expect(context.playback.currentTrack?.title == "Blue Hour")
    #expect(context.showPlanSummary.contains("克制"))
    #expect(context.hostPreference?.contains("歌曲事实") == true)
    #expect(context.immediateUserInstruction == "少说一点")
}

@Test
func realtimeContextCarriesTrackFactsForTheNextHostBreak() {
    let current = TrackReference(
        id: "current",
        title: "Blue Hour",
        artist: "Example Artist"
    )
    let next = TrackReference(
        id: "next",
        title: "Night Drive",
        artist: "Second Artist"
    )
    let hint = ProgramHostHint(
        shouldTalkBefore: true,
        maxSentenceCount: 1,
        selectionReason: "符合深夜工作氛围",
        currentTrack: current,
        nextTrack: next,
        facts: ["发行年份：2024", "风格：电子"],
        transitionIntent: "保持相近能量，延续当前质感"
    )

    let context = RealtimeDJContext(
        playback: PlaybackContext(currentTrack: current),
        showPlanSummary: "深夜工作节目",
        hostHint: hint
    )

    #expect(context.hostHint == hint)
    #expect(context.hostHint?.nextTrack?.title == "Night Drive")
    #expect(context.hostHint?.maxSentenceCount == 1)
}

@Test
func realtimeContextAdvertisesTheCurrentAgentControlSurface() {
    let control = DJAgentRadioState(
        takeoverEnabled: true,
        playbackState: "playing",
        activeTrackID: "current",
        activeSlotIndex: 0,
        program: [
            DJAgentProgramTrack(
                index: 0,
                id: "current",
                title: "Blue Hour",
                artist: "Example Artist"
            ),
        ]
    )
    let context = RealtimeDJContext(
        playback: PlaybackContext(),
        showPlanSummary: "深夜工作节目",
        agentControl: control
    )

    #expect(context.agentControl == control)
    #expect(context.agentControl?.takeoverEnabled == true)
    #expect(
        context.agentControl?.capabilities
            .contains { $0.name == "play_program_track" } == true
    )
}
