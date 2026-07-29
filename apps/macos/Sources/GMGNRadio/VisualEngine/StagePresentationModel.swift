import Combine
import Foundation

struct StageLyricLine: Identifiable, Equatable, Sendable {
    let id: String
    let startsAt: TimeInterval
    let text: String

    init(
        id: String = UUID().uuidString,
        startsAt: TimeInterval,
        text: String
    ) {
        self.id = id
        self.startsAt = startsAt
        self.text = text
    }
}

struct LRCParser {
    private let timestampExpression = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#
    )

    func parse(_ source: String) -> [StageLyricLine] {
        source
            .components(separatedBy: .newlines)
            .flatMap(parseLine)
            .sorted {
                if $0.startsAt == $1.startsAt {
                    return $0.id < $1.id
                }
                return $0.startsAt < $1.startsAt
            }
    }

    private func parseLine(_ sourceLine: String) -> [StageLyricLine] {
        let range = NSRange(sourceLine.startIndex..., in: sourceLine)
        let matches = timestampExpression.matches(
            in: sourceLine,
            range: range
        )
        guard !matches.isEmpty else {
            return []
        }

        let text = timestampExpression
            .stringByReplacingMatches(
                in: sourceLine,
                range: range,
                withTemplate: ""
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return []
        }

        return matches.compactMap { match in
            guard
                let minuteRange = Range(match.range(at: 1), in: sourceLine),
                let secondRange = Range(match.range(at: 2), in: sourceLine),
                let minutes = Double(sourceLine[minuteRange]),
                let seconds = Double(sourceLine[secondRange])
            else {
                return nil
            }
            let fraction: Double
            if
                match.range(at: 3).location != NSNotFound,
                let fractionRange = Range(match.range(at: 3), in: sourceLine)
            {
                let value = sourceLine[fractionRange]
                fraction = (Double(value) ?? 0)
                    / pow(10, Double(value.count))
            } else {
                fraction = 0
            }
            let start = minutes * 60 + seconds + fraction
            return StageLyricLine(
                id: "\(start)-\(match.range.location)-\(text)",
                startsAt: start,
                text: text
            )
        }
    }
}

struct StageLyricSceneLine: Equatable, Identifiable {
    let lyric: StageLyricLine
    let position: Int
    let depth: Double
    let opacity: Double
    let blurRadius: Double
    let scale: Double

    var id: String {
        lyric.id
    }

    var text: String {
        lyric.text
    }
}

struct StageLyricSceneModel: Equatable {
    let lines: [StageLyricSceneLine]

    init(lines: [StageLyricLine], playbackTime: TimeInterval) {
        guard
            let activeIndex = lines.lastIndex(where: {
                $0.startsAt <= playbackTime
            })
        else {
            self.lines = []
            return
        }

        let visibleRange = max(lines.startIndex, activeIndex - 1)
            ... min(lines.index(before: lines.endIndex), activeIndex + 1)
        self.lines = visibleRange.map { index in
            let position = index - activeIndex
            switch position {
            case -1:
                return StageLyricSceneLine(
                    lyric: lines[index],
                    position: position,
                    depth: -72,
                    opacity: 0.3,
                    blurRadius: 2.4,
                    scale: 0.82
                )
            case 1:
                return StageLyricSceneLine(
                    lyric: lines[index],
                    position: position,
                    depth: -108,
                    opacity: 0.46,
                    blurRadius: 1.5,
                    scale: 0.9
                )
            default:
                return StageLyricSceneLine(
                    lyric: lines[index],
                    position: 0,
                    depth: 0,
                    opacity: 1,
                    blurRadius: 0,
                    scale: 1
                )
            }
        }
    }
}

@MainActor
final class StageLyricsStore: ObservableObject {
    static let shared = StageLyricsStore()

    @Published private(set) var trackID: String?
    @Published private(set) var lines: [StageLyricLine] = []

    func publish(_ lyrics: MusicLyrics, trackID: String) {
        self.trackID = trackID
        lines = LRCParser().parse(lyrics.original)
    }

    func clear() {
        trackID = nil
        lines = []
    }
}

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
