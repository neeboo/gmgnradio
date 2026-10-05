import Combine
import Foundation

struct StageLyricWord: Identifiable, Equatable, Sendable {
    let id: String
    let startsAt: TimeInterval
    let endsAt: TimeInterval
    let text: String

    init(
        id: String = UUID().uuidString,
        startsAt: TimeInterval,
        endsAt: TimeInterval,
        text: String
    ) {
        self.id = id
        self.startsAt = startsAt
        self.endsAt = max(endsAt, startsAt + 0.01)
        self.text = text
    }
}

struct StageLyricLine: Identifiable, Equatable, Sendable {
    let id: String
    let startsAt: TimeInterval
    let endsAt: TimeInterval
    let text: String
    let translation: String?
    let words: [StageLyricWord]

    init(
        id: String = UUID().uuidString,
        startsAt: TimeInterval,
        endsAt: TimeInterval? = nil,
        text: String,
        translation: String? = nil,
        words: [StageLyricWord] = []
    ) {
        self.id = id
        self.startsAt = startsAt
        self.endsAt = max(endsAt ?? startsAt + 5, startsAt + 0.01)
        self.text = text
        self.translation = translation
        self.words = words
    }
}

enum StageLyricTokenization {
    static func displayUnits(in text: String) -> [String] {
        var units: [String] = []
        var word = ""

        func flushWord() {
            guard !word.isEmpty else {
                return
            }
            units.append(word)
            word = ""
        }

        for character in text {
            if isCJK(character) {
                flushWord()
                units.append(String(character))
            } else if character.isWhitespace {
                if !word.isEmpty {
                    word.append(character)
                    flushWord()
                } else if !units.isEmpty {
                    units[units.index(before: units.endIndex)]
                        .append(character)
                } else {
                    word.append(character)
                }
            } else if isPunctuation(character) {
                if !word.isEmpty {
                    word.append(character)
                } else if !units.isEmpty {
                    units[units.index(before: units.endIndex)]
                        .append(character)
                } else {
                    word.append(character)
                }
            } else {
                word.append(character)
            }
        }
        flushWord()
        return units
    }

    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400 ... 0x4DBF,
                 0x4E00 ... 0x9FFF,
                 0xF900 ... 0xFAFF,
                 0x20000 ... 0x2CEAF:
                true
            default:
                false
            }
        }
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        String(character).rangeOfCharacter(
            from: .punctuationCharacters
        ) != nil
    }
}

struct LRCParser {
    private let timestampExpression = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#
    )

    func parse(
        _ source: String,
        translation: String? = nil,
        trackDuration: TimeInterval? = nil
    ) -> [StageLyricLine] {
        let rawLines = source
            .components(separatedBy: .newlines)
            .flatMap(parseLine)
            .sorted {
                if $0.startsAt == $1.startsAt {
                    return $0.id < $1.id
                }
                return $0.startsAt < $1.startsAt
            }
        let translated = translation.map {
            $0.components(separatedBy: .newlines)
                .flatMap(parseLine)
                .sorted { $0.startsAt < $1.startsAt }
        } ?? []

        return rawLines.enumerated().map { index, rawLine in
            let nextStart = rawLines.indices.contains(index + 1)
                ? rawLines[index + 1].startsAt
                : nil
            let estimatedEnd = rawLine.startsAt
                + estimatedLineDuration(for: rawLine.text)
            let boundedNext = nextStart.map {
                min($0, rawLine.startsAt + 6)
            }
            let boundedTrackEnd = trackDuration.flatMap {
                $0 > rawLine.startsAt ? $0 : nil
            }
            let end = max(
                rawLine.startsAt + 0.1,
                boundedNext
                    ?? boundedTrackEnd
                    ?? estimatedEnd
            )
            return StageLyricLine(
                id: rawLine.id,
                startsAt: rawLine.startsAt,
                endsAt: end,
                text: rawLine.text,
                translation: matchingTranslation(
                    at: rawLine.startsAt,
                    lines: translated
                ),
                words: synthesizedWords(
                    text: rawLine.text,
                    startsAt: rawLine.startsAt,
                    endsAt: end,
                    lineID: rawLine.id
                )
            )
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
                endsAt: start + 0.1,
                text: text
            )
        }
    }

    private func matchingTranslation(
        at startsAt: TimeInterval,
        lines: [StageLyricLine]
    ) -> String? {
        lines
            .min {
                abs($0.startsAt - startsAt) < abs($1.startsAt - startsAt)
            }
            .flatMap {
                abs($0.startsAt - startsAt) <= 0.75 ? $0.text : nil
            }
    }

    private func estimatedLineDuration(for text: String) -> TimeInterval {
        min(max(Double(text.count) * 0.42, 1.8), 6)
    }

    private func synthesizedWords(
        text: String,
        startsAt: TimeInterval,
        endsAt: TimeInterval,
        lineID: String
    ) -> [StageLyricWord] {
        let units = StageLyricTokenization.displayUnits(in: text)
        guard !units.isEmpty else {
            return []
        }
        let weights = units.map { unit -> Double in
            let visible = unit.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if visible.isEmpty {
                return 0.3
            }
            if visible.rangeOfCharacter(
                from: .alphanumerics
            ) == nil, !visible.contains(where: {
                StageLyricTokenization.isCJK($0)
            }) {
                return 0.35
            }
            if visible.contains(where: {
                StageLyricTokenization.isCJK($0)
            }) {
                return 1
            }
            return min(max(Double(visible.count) * 0.55, 1), 3)
        }
        let totalWeight = max(weights.reduce(0, +), 0.1)
        let duration = endsAt - startsAt
        var cursor = startsAt
        return zip(units.indices, zip(units, weights)).map {
            index, pair in
            let (unit, weight) = pair
            let wordEnd = index == units.indices.last
                ? endsAt
                : cursor + duration * weight / totalWeight
            defer {
                cursor = wordEnd
            }
            return StageLyricWord(
                id: "\(lineID)-\(index)",
                startsAt: cursor,
                endsAt: wordEnd,
                text: unit
            )
        }
    }
}

struct YRCParser {
    private let lineExpression = try! NSRegularExpression(
        pattern: #"^\[(\d+),(\d+)\](.*)$"#
    )
    private let wordExpression = try! NSRegularExpression(
        pattern: #"\((\d+),(\d+),\d+\)([^\(]*)"#
    )

    func parse(
        _ source: String,
        translation: String? = nil
    ) -> [StageLyricLine] {
        let translationLines = LRCParser().parse(translation ?? "")
        return source
            .components(separatedBy: .newlines)
            .enumerated()
            .compactMap { index, sourceLine in
                parseLine(
                    sourceLine,
                    index: index,
                    translationLines: translationLines
                )
            }
            .sorted { $0.startsAt < $1.startsAt }
    }

    private func parseLine(
        _ sourceLine: String,
        index: Int,
        translationLines: [StageLyricLine]
    ) -> StageLyricLine? {
        let sourceRange = NSRange(sourceLine.startIndex..., in: sourceLine)
        guard
            let lineMatch = lineExpression.firstMatch(
                in: sourceLine,
                range: sourceRange
            ),
            let startRange = Range(lineMatch.range(at: 1), in: sourceLine),
            let durationRange = Range(lineMatch.range(at: 2), in: sourceLine),
            let contentRange = Range(lineMatch.range(at: 3), in: sourceLine),
            let lineStartMS = Double(sourceLine[startRange]),
            let lineDurationMS = Double(sourceLine[durationRange])
        else {
            return nil
        }

        let lineStart = lineStartMS / 1_000
        let lineEnd = max(
            (lineStartMS + lineDurationMS) / 1_000,
            lineStart + 0.1
        )
        let content = String(sourceLine[contentRange])
        let contentNSRange = NSRange(content.startIndex..., in: content)
        let lineID = "yrc-\(Int(lineStartMS))-\(index)"
        let words = wordExpression.matches(
            in: content,
            range: contentNSRange
        ).enumerated().compactMap { wordIndex, match -> StageLyricWord? in
            guard
                let startRange = Range(match.range(at: 1), in: content),
                let durationRange = Range(match.range(at: 2), in: content),
                let textRange = Range(match.range(at: 3), in: content),
                let rawStartMS = Double(content[startRange]),
                let durationMS = Double(content[durationRange])
            else {
                return nil
            }
            let text = String(content[textRange])
            guard !text.isEmpty else {
                return nil
            }
            let absoluteStartMS = rawStartMS + (
                rawStartMS + 1_000 < lineStartMS ? lineStartMS : 0
            )
            let wordStart = min(max(absoluteStartMS / 1_000, lineStart), lineEnd)
            let wordEnd = min(
                max(
                    (absoluteStartMS + durationMS) / 1_000,
                    wordStart + 0.01
                ),
                lineEnd
            )
            return StageLyricWord(
                id: "\(lineID)-\(wordIndex)",
                startsAt: wordStart,
                endsAt: wordEnd,
                text: text
            )
        }
        guard !words.isEmpty else {
            return nil
        }
        let fullText = words.map(\.text).joined()
        let translated = translationLines.min {
            abs($0.startsAt - lineStart) < abs($1.startsAt - lineStart)
        }.flatMap {
            abs($0.startsAt - lineStart) <= 0.75 ? $0.text : nil
        }
        return StageLyricLine(
            id: lineID,
            startsAt: lineStart,
            endsAt: lineEnd,
            text: fullText,
            translation: translated,
            words: words
        )
    }
}

struct StageLyricsParser {
    func parse(
        _ lyrics: MusicLyrics,
        trackDuration: TimeInterval? = nil
    ) -> [StageLyricLine] {
        if let wordByWord = lyrics.wordByWord {
            let precise = YRCParser().parse(
                wordByWord,
                translation: lyrics.translation
            )
            if !precise.isEmpty {
                return precise
            }
        }
        return LRCParser().parse(
            lyrics.original,
            translation: lyrics.translation,
            trackDuration: trackDuration
        )
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

enum StageLyricsVisualMode: CaseIterable, Equatable, Hashable, Sendable {
    case automatic
    case flowingLine
    case depthStack
    case cloudSteps
    case chorusChat
    case cinematicSplit
    case orbitArc
    case posterRail
    case editorialField
    case pendulumWheel
    case dioramaStage
    case foldingVerse

    static let playbackModes: [StageLyricsVisualMode] = [
        .flowingLine,
        .depthStack,
        .cloudSteps,
        .editorialField,
        .chorusChat,
        .cinematicSplit,
        .orbitArc,
        .posterRail,
        .pendulumWheel,
        .dioramaStage,
        .foldingVerse,
    ]

    static let agentValues = ["automatic"]
        + playbackModes.map(\.agentValue)

    var agentValue: String {
        switch self {
        case .automatic:
            "automatic"
        case .flowingLine:
            "luminous"
        case .depthStack:
            "mindscape"
        case .cloudSteps:
            "cloud_steps"
        case .editorialField:
            "article"
        case .chorusChat:
            "chorus_chat"
        case .cinematicSplit:
            "confession"
        case .orbitArc:
            "claddagh"
        case .posterRail:
            "monet_poster"
        case .pendulumWheel:
            "pendulum"
        case .dioramaStage:
            "diorama"
        case .foldingVerse:
            "folding_verse"
        }
    }

    var displayName: String {
        switch self {
        case .automatic:
            "自动"
        case .flowingLine:
            "流光"
        case .depthStack:
            "心象"
        case .cloudSteps:
            "云阶"
        case .editorialField:
            "浮名"
        case .chorusChat:
            "群唱"
        case .cinematicSplit:
            "倾诉"
        case .orbitArc:
            "回环"
        case .posterRail:
            "莫奈"
        case .pendulumWheel:
            "时计"
        case .dioramaStage:
            "镜台"
        case .foldingVerse:
            "折章"
        }
    }

    var symbolName: String {
        switch self {
        case .automatic:
            "sparkles"
        case .flowingLine:
            "textformat"
        case .depthStack:
            "square.3.layers.3d"
        case .cloudSteps:
            "chart.bar.doc.horizontal"
        case .editorialField:
            "doc.richtext"
        case .chorusChat:
            "message.fill"
        case .cinematicSplit:
            "text.line.first.and.arrowtriangle.forward"
        case .orbitArc:
            "circle.dotted.circle"
        case .posterRail:
            "rectangle.portrait"
        case .pendulumWheel:
            "clock.arrow.circlepath"
        case .dioramaStage:
            "cube.transparent"
        case .foldingVerse:
            "rectangle.portrait.on.rectangle.portrait"
        }
    }

    init?(agentValue: String) {
        switch agentValue {
        case "automatic":
            self = .automatic
        case "luminous", "flowing_line":
            self = .flowingLine
        case "mindscape", "depth_stack":
            self = .depthStack
        case "cloud_steps":
            self = .cloudSteps
        case "article", "editorial_field":
            self = .editorialField
        case "chorus_chat":
            self = .chorusChat
        case "confession", "cinematic_split":
            self = .cinematicSplit
        case "claddagh", "orbit_arc":
            self = .orbitArc
        case "monet_poster", "poster_rail":
            self = .posterRail
        case "pendulum":
            self = .pendulumWheel
        case "diorama":
            self = .dioramaStage
        case "folding_verse", "folding":
            self = .foldingVerse
        default:
            return nil
        }
    }
}

enum StageLyricModeDirector {
    static func resolve(
        configuredMode: StageLyricsVisualMode,
        trackID: String?,
        lines: [StageLyricLine],
        playbackTime: TimeInterval
    ) -> StageLyricsVisualMode {
        guard configuredMode == .automatic else {
            return configuredMode
        }
        let seed = stableSeed(trackID ?? "")
        return StageLyricsVisualMode.playbackModes[
            seed % StageLyricsVisualMode.playbackModes.count
        ]
    }

    private static func stableSeed(_ value: String) -> Int {
        value.utf8.reduce(0) { partial, byte in
            (partial &* 31 &+ Int(byte)) & 0x7FFF_FFFF
        }
    }
}

enum StageLyricTypography {
    static func fontSize(
        text: String,
        availableWidth: Double
    ) -> Double {
        let visibleCount = max(
            text.filter { !$0.isWhitespace }.count,
            6
        )
        let proposed = availableWidth * 0.78
            / Double(visibleCount)
            * 0.92
        return min(max(proposed, 18), 112)
    }
}

enum StageLyricGlyphPhase: Equatable, Sendable {
    case waiting
    case active
    case passed
}

enum StageLyricRenderPolicy {
    static let minimumFrameInterval: TimeInterval = 1.0 / 60.0

    static func shouldRenderDynamicGlow(
        for phase: StageLyricGlyphPhase
    ) -> Bool {
        phase == .active
    }
}

struct StageLyricAudioMotion: Equatable, Sendable {
    let expansion: Double
    let beatLift: Double
    let glow: Double
    let particleEnergy: Double
    let low: Double
    let mid: Double
    let high: Double
    let beat: Double
    let onset: Double
    let amplitude: Double
    let sceneEnergy: Double

    init(
        features: VisualAudioFeatures,
        animationTime: TimeInterval,
        mode: StageLyricsVisualMode = .automatic
    ) {
        low = Double(features.low)
        mid = Double(features.mid)
        high = Double(features.high)
        beat = Double(features.beat)
        onset = Double(features.onset)
        amplitude = Double(features.amplitude)
        sceneEnergy = mode.foliaProfile.audioFocus.energy(from: features)
        expansion = 1
        beatLift = 0
        glow = 0.14 + amplitude * 0.34
            + sceneEnergy * 0.34
            + high * 0.12
        particleEnergy = amplitude * 0.22
            + sceneEnergy * 0.4
            + low * 0.12
            + mid * 0.1
            + high * 0.08
            + onset * 0.32
    }
}

struct StageLyricGlyphFrame: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let phase: StageLyricGlyphPhase
    let progress: Double
    let xOffset: Double
    let yOffset: Double
    let rotation: Double
    let restingScale: Double
}

struct StageLyricFlowSceneModel: Equatable, Sendable {
    let activeLine: StageLyricLine?
    let previousLine: StageLyricLine?
    let nextLine: StageLyricLine?
    let translation: String?
    let glyphs: [StageLyricGlyphFrame]
    let lineProgress: Double
    let isChorus: Bool

    init(lines: [StageLyricLine], playbackTime: TimeInterval) {
        guard
            let activeIndex = lines.lastIndex(where: {
                $0.startsAt <= playbackTime
            })
        else {
            activeLine = nil
            previousLine = nil
            nextLine = nil
            translation = nil
            glyphs = []
            lineProgress = 0
            isChorus = false
            return
        }

        let line = lines[activeIndex]
        activeLine = line
        previousLine = activeIndex > lines.startIndex
            ? lines[lines.index(before: activeIndex)]
            : nil
        nextLine = activeIndex < lines.index(before: lines.endIndex)
            ? lines[lines.index(after: activeIndex)]
            : nil
        translation = line.translation
        let lineDuration = max(line.endsAt - line.startsAt, 0.01)
        lineProgress = min(
            max((playbackTime - line.startsAt) / lineDuration, 0),
            1
        )
        isChorus = StageLyricSectionClassifier.isChorus(
            line,
            among: lines
        )
        glyphs = Self.makeGlyphs(
            line: line,
            playbackTime: playbackTime
        )
    }

    private static func makeGlyphs(
        line: StageLyricLine,
        playbackTime: TimeInterval
    ) -> [StageLyricGlyphFrame] {
        let sourceWords = line.words.isEmpty
            ? [
                StageLyricWord(
                    id: "\(line.id)-fallback",
                    startsAt: line.startsAt,
                    endsAt: line.endsAt,
                    text: line.text
                ),
            ]
            : line.words
        var glyphIndex = 0
        return sourceWords.flatMap { word -> [StageLyricGlyphFrame] in
            let units = StageLyricTokenization.displayUnits(in: word.text)
            guard !units.isEmpty else {
                return []
            }
            let duration = max(word.endsAt - word.startsAt, 0.01)
            return units.enumerated().map { index, unit in
                let start = word.startsAt
                    + duration * Double(index) / Double(units.count)
                let end = word.startsAt
                    + duration * Double(index + 1) / Double(units.count)
                let phase: StageLyricGlyphPhase
                if playbackTime < start {
                    phase = .waiting
                } else if playbackTime >= end {
                    phase = .passed
                } else {
                    phase = .active
                }
                let progress = min(
                    max((playbackTime - start) / max(end - start, 0.01), 0),
                    1
                )
                let currentIndex = glyphIndex
                glyphIndex += 1
                return StageLyricGlyphFrame(
                    id: "\(word.id)-\(index)",
                    text: unit,
                    phase: phase,
                    progress: progress,
                    xOffset: stableValue(
                        lineID: line.id,
                        index: currentIndex,
                        salt: 11,
                        range: -3 ... 3
                    ),
                    yOffset: stableValue(
                        lineID: line.id,
                        index: currentIndex,
                        salt: 23,
                        range: -8 ... 8
                    ),
                    rotation: stableValue(
                        lineID: line.id,
                        index: currentIndex,
                        salt: 37,
                        range: -2.8 ... 2.8
                    ),
                    restingScale: stableValue(
                        lineID: line.id,
                        index: currentIndex,
                        salt: 53,
                        range: 0.94 ... 1.04
                    )
                )
            }
        }
    }

    private static func stableValue(
        lineID: String,
        index: Int,
        salt: UInt64,
        range: ClosedRange<Double>
    ) -> Double {
        var hash: UInt64 = 14_695_981_039_346_656_037 ^ salt
        for byte in "\(lineID)-\(index)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let unit = Double(hash % 10_000) / 9_999
        return range.lowerBound
            + (range.upperBound - range.lowerBound) * unit
    }
}

enum StageLyricFoldDirection: Equatable, Sendable {
    case left
    case right
}

struct StageLyricFoldSceneModel: Equatable, Sendable {
    static let maximumLinesPerGroup = 4
    static let paragraphGap: TimeInterval = 5
    static let transitionDuration: TimeInterval = 0.72

    let groupIndex: Int
    let previousLines: [StageLyricLine]
    let currentLines: [StageLyricLine]
    let activeLineID: String?
    let foldDirection: StageLyricFoldDirection
    let transitionProgress: Double

    init(lines: [StageLyricLine], playbackTime: TimeInterval) {
        let sortedLines = lines.sorted {
            if $0.startsAt == $1.startsAt {
                return $0.id < $1.id
            }
            return $0.startsAt < $1.startsAt
        }
        let groups = Self.makeGroups(from: sortedLines)

        guard !groups.isEmpty else {
            groupIndex = 0
            previousLines = []
            currentLines = []
            activeLineID = nil
            foldDirection = .left
            transitionProgress = 0
            return
        }

        let activeLine = sortedLines.last(where: {
            $0.startsAt <= playbackTime
        })
        let resolvedGroupIndex = activeLine.flatMap { line in
            groups.firstIndex(where: { group in
                group.contains(where: { $0.id == line.id })
            })
        } ?? 0
        let currentGroup = groups[resolvedGroupIndex]
        let groupStart = currentGroup.first?.startsAt ?? playbackTime

        groupIndex = resolvedGroupIndex
        previousLines = resolvedGroupIndex > 0
            ? groups[resolvedGroupIndex - 1]
            : []
        currentLines = currentGroup
        activeLineID = activeLine?.id
        foldDirection = resolvedGroupIndex.isMultiple(of: 2)
            ? .left
            : .right
        transitionProgress = min(
            max(
                (playbackTime - groupStart) / Self.transitionDuration,
                0
            ),
            1
        )
    }

    private static func makeGroups(
        from lines: [StageLyricLine]
    ) -> [[StageLyricLine]] {
        var groups: [[StageLyricLine]] = []
        var currentGroup: [StageLyricLine] = []

        for line in lines {
            let previousLine = currentGroup.last
            let startsNewParagraph = previousLine.map {
                line.startsAt - $0.startsAt >= paragraphGap
            } ?? false
            if currentGroup.count >= maximumLinesPerGroup
                || startsNewParagraph
            {
                groups.append(currentGroup)
                currentGroup = []
            }
            currentGroup.append(line)
        }

        if !currentGroup.isEmpty {
            groups.append(currentGroup)
        }
        return groups
    }
}

enum StageLyricSectionClassifier {
    static func isChorus(
        _ line: StageLyricLine,
        among lines: [StageLyricLine]
    ) -> Bool {
        let target = normalized(line.text)
        guard target.count >= 2 else {
            return false
        }
        return lines.lazy
            .map { normalized($0.text) }
            .filter { $0 == target }
            .prefix(2)
            .count == 2
    }

    private static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .filter {
                !$0.isWhitespace
                    && String($0).rangeOfCharacter(
                        from: .punctuationCharacters
                    ) == nil
            }
    }
}

@MainActor
final class StageLyricsStore: ObservableObject {
    static let shared = StageLyricsStore(defaults: .standard)
    static let visualModePreferenceKey = "stage.lyrics.visualMode"
    private let defaults: UserDefaults?

    @Published private(set) var trackID: String?
    @Published private(set) var lines: [StageLyricLine] = []
    @Published private(set) var visualMode: StageLyricsVisualMode = .automatic
    @Published private(set) var activeTheme: StageAITheme?

    /// Explicit injection keeps test stores and isolated render hosts from
    /// reading or writing the installed application's preference domain.
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let stored = defaults?.string(forKey: Self.visualModePreferenceKey),
           let mode = StageLyricsVisualMode.allCases.first(where: { $0.agentValue == stored }) {
            visualMode = mode
        }
    }

    func publish(
        _ lyrics: MusicLyrics,
        trackID: String,
        trackDuration: TimeInterval? = nil
    ) {
        if self.trackID != trackID {
            activeTheme = nil
        }
        self.trackID = trackID
        lines = StageLyricsParser().parse(
            lyrics,
            trackDuration: trackDuration
        )
    }

    func setVisualMode(_ mode: StageLyricsVisualMode) {
        visualMode = mode
        defaults?.set(mode.agentValue, forKey: Self.visualModePreferenceKey)
    }

    @discardableResult
    func apply(
        theme: StageAITheme,
        requestedForTrackID: String
    ) -> Bool {
        guard trackID == requestedForTrackID else {
            return false
        }
        activeTheme = theme
        return true
    }

    func clear() {
        trackID = nil
        lines = []
        activeTheme = nil
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

enum StageDJCaptionFormatter {
    static let defaultMaximumCharacters = 32

    static func pages(
        for text: String,
        maxCharacters: Int = defaultMaximumCharacters
    ) -> [String] {
        let limit = max(maxCharacters, 8)
        guard !text.isEmpty else {
            return []
        }

        var pages: [String] = []
        var current = ""
        var lastBreakOffset: Int?

        func flush(_ count: Int? = nil) {
            let splitCount = count ?? current.count
            guard splitCount > 0 else {
                return
            }
            let splitIndex = current.index(
                current.startIndex,
                offsetBy: splitCount
            )
            pages.append(String(current[..<splitIndex]))
            current = String(current[splitIndex...])
            lastBreakOffset = lastBreakOffset.flatMap {
                let shifted = $0 - splitCount
                return shifted > 0 ? shifted : nil
            }
        }

        for character in text {
            current.append(character)
            if isBreakOpportunity(character) {
                lastBreakOffset = current.count
            }

            if current.count >= limit {
                let minimumNaturalBreak = max(limit / 2, 1)
                if
                    let breakOffset = lastBreakOffset,
                    breakOffset >= minimumNaturalBreak
                {
                    flush(breakOffset)
                } else {
                    flush(limit)
                }
            } else if
                isSentenceEnding(character),
                current.count >= max(limit / 2, 1)
            {
                flush()
            }
        }

        if !current.isEmpty {
            pages.append(current)
        }
        return pages
    }

    static func visiblePage(for text: String) -> (text: String, index: Int)? {
        let pages = pages(for: text)
        guard let text = pages.last else {
            return nil
        }
        return (text, pages.count - 1)
    }

    static func visibleWindow(
        for text: String,
        maxCharacters: Int = defaultMaximumCharacters,
        maximumPages: Int = 1
    ) -> (text: String, index: Int)? {
        let pages = pages(for: text, maxCharacters: maxCharacters)
        guard !pages.isEmpty else {
            return nil
        }
        let windowSize = max(maximumPages, 1)
        return (
            pages.suffix(windowSize).joined(separator: "\n"),
            pages.count - 1
        )
    }

    private static func isBreakOpportunity(
        _ character: Character
    ) -> Bool {
        character.isWhitespace
            || "，,。！？!?；;：:".contains(character)
    }

    private static func isSentenceEnding(
        _ character: Character
    ) -> Bool {
        "。！？!?；;".contains(character)
    }
}

@MainActor
final class StagePresentationModel: ObservableObject {
    @Published private(set) var programTitle: String
    @Published private(set) var programDetail: String
    @Published private(set) var currentCue: StageTextCue?
    private var liveTranscript = ""
    private var isAgentResponseActive = true

    init(
        programTitle: String = "",
        programDetail: String = "",
        currentCue: StageTextCue? = nil
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

        currentCue = nil
    }

    func consume(_ event: RealtimeDJEvent) {
        switch event {
        case .agentResponseStarted:
            liveTranscript = ""
            isAgentResponseActive = true
        case .agentAudioStarted:
            if !isAgentResponseActive {
                liveTranscript = ""
            }
            isAgentResponseActive = true
        case let .agentTranscriptDelta(delta):
            guard isAgentResponseActive else {
                return
            }
            liveTranscript += delta
            presentLiveTranscript(liveTranscript)
        case let .agentTranscriptFinal(text):
            guard isAgentResponseActive else {
                return
            }
            liveTranscript = text
            presentLiveTranscript(text)
        case .agentAudioFinished:
            isAgentResponseActive = false
            liveTranscript = ""
            currentCue = nil
        case .interrupted:
            isAgentResponseActive = false
            liveTranscript = ""
            currentCue = nil
        default:
            break
        }
    }

    private func presentLiveTranscript(_ text: String) {
        guard
            let page = StageDJCaptionFormatter.visibleWindow(for: text)
        else {
            return
        }
        currentCue = StageTextCue(
            id: "live-dj-transcript-\(page.index)",
            text: page.text,
            secondaryText: nil,
            startsAt: 0,
            endsAt: .infinity,
            emphasis: 1
        )
    }
}
