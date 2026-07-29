import Combine
import Foundation

struct StageTextCue: Identifiable, Equatable, Sendable {
    let id: String
    var text: String
    var secondaryText: String?
    var startsAt: TimeInterval
    var endsAt: TimeInterval
    var emphasis: Float

    init(
        id: String = UUID().uuidString,
        text: String,
        secondaryText: String?,
        startsAt: TimeInterval,
        endsAt: TimeInterval,
        emphasis: Float = 1
    ) {
        self.id = id
        self.text = text
        self.secondaryText = secondaryText
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.emphasis = min(max(emphasis, 0), 1)
    }

    func isActive(at time: TimeInterval) -> Bool {
        startsAt <= time && time < endsAt
    }
}

@MainActor
final class StagePresentationModel: ObservableObject {
    @Published private(set) var programTitle: String
    @Published private(set) var programDetail: String
    @Published private(set) var currentCue: StageTextCue?
    private var liveTranscript = ""

    init(
        programTitle: String = "AFTERGLOW SESSION",
        programDetail: String = "DJ 自主节目",
        currentCue: StageTextCue? = StageTextCue(
            text: "凌晨两点，让城市先慢下来。",
            secondaryText: "接下来这首歌，会留一点空间给你。",
            startsAt: 0,
            endsAt: .infinity
        )
    ) {
        self.programTitle = programTitle
        self.programDetail = programDetail
        self.currentCue = currentCue
    }

    func updateProgram(title: String, detail: String) {
        programTitle = title
        programDetail = detail
    }

    func present(_ cue: StageTextCue?) {
        currentCue = cue
    }

    func update(cues: [StageTextCue], at programTime: TimeInterval) {
        currentCue = cues.first { $0.isActive(at: programTime) }
    }

    func apply(_ context: RealtimeDJContext) {
        if !context.showPlanSummary.isEmpty {
            programTitle = context.showPlanSummary
        }

        if let track = context.playback.currentTrack {
            programDetail = [track.title, track.artist]
                .compactMap { $0 }
                .joined(separator: " — ")
        }

        guard
            let hint = context.hostHint,
            hint.shouldTalkBefore
        else {
            currentCue = nil
            return
        }

        currentCue = StageTextCue(
            id: "host-hint-\(hint.currentTrack.id)",
            text: hint.selectionReason,
            secondaryText: hint.transitionIntent,
            startsAt: 0,
            endsAt: .infinity,
            emphasis: 0.76
        )
    }

    func consume(_ event: RealtimeDJEvent) {
        switch event {
        case .agentResponseStarted:
            liveTranscript = ""
        case let .agentTranscriptDelta(delta):
            liveTranscript += delta
            presentLiveTranscript(liveTranscript)
        case let .agentTranscriptFinal(text):
            liveTranscript = text
            presentLiveTranscript(text)
        case .interrupted:
            liveTranscript = ""
            currentCue = nil
        default:
            break
        }
    }

    private func presentLiveTranscript(_ text: String) {
        guard !text.isEmpty else {
            return
        }
        currentCue = StageTextCue(
            id: "live-dj-transcript",
            text: text,
            secondaryText: nil,
            startsAt: 0,
            endsAt: .infinity,
            emphasis: 1
        )
    }
}
