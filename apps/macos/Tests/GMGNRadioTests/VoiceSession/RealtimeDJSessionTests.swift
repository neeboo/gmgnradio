import Foundation
import Testing
@testable import GMGNRadio

@Test
func providersExposeTheirVerifiedRealtimeCapabilities() {
    let bailian = RealtimeDJProvider.bailian.capabilities
    let doubao = RealtimeDJProvider.doubao.capabilities

    #expect(bailian.transport == .streamingWebSocket)
    #expect(bailian.serverVoiceActivityDetection)
    #expect(bailian.liveContextUpdates)
    #expect(bailian.clientTools)

    #expect(doubao.transport == .rtcRoom)
    #expect(doubao.serverVoiceActivityDetection)
    #expect(doubao.nativeInterruption)
    #expect(doubao.clientTools)
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
        immediateUserInstruction: "少说一点"
    )

    #expect(context.playback.currentTrack?.title == "Blue Hour")
    #expect(context.showPlanSummary.contains("克制"))
    #expect(context.immediateUserInstruction == "少说一点")
}
