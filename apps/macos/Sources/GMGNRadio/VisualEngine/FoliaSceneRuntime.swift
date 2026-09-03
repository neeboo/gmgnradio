import Foundation

// Portions of this scene runtime are based on the visualizer architecture in
// chthollyphile/folia-major, commit 002b581bb2580566937f1023a3c875d2b799dbbe.
// Rewritten for SwiftUI and Metal by gmgn radio contributors on 2026-07-31.
// Folia and this modified work are licensed under GNU AGPL v3.
// See LICENSE and THIRD_PARTY_NOTICES.md in the repository root.

enum StageLyricsRenderingBackend: Equatable, Sendable {
    case swiftUI
    case metal
}

enum StageFoliaAudioFocus: Equatable, Sendable {
    case vocalAndTreble
    case vocal
    case midAndVocal
    case lowMidAndVocal
    case vocalAndOnset
    case bassAndVocal
    case midAndTreble
    case lowMidAndMid
    case bassAndBeat
    case fullSpectrum

    func energy(from features: VisualAudioFeatures) -> Double {
        let value: Float = switch self {
        case .vocalAndTreble:
            features.vocal * 0.68 + features.treble * 0.32
        case .vocal:
            features.vocal
        case .midAndVocal:
            features.sceneMid * 0.48 + features.vocal * 0.52
        case .lowMidAndVocal:
            features.lowMid * 0.42 + features.vocal * 0.58
        case .vocalAndOnset:
            features.vocal * 0.72 + features.onset * 0.28
        case .bassAndVocal:
            features.bass * 0.46 + features.vocal * 0.54
        case .midAndTreble:
            features.sceneMid * 0.58 + features.treble * 0.42
        case .lowMidAndMid:
            features.lowMid * 0.5 + features.sceneMid * 0.5
        case .bassAndBeat:
            features.bass * 0.62 + features.beat * 0.38
        case .fullSpectrum:
            (
                features.bass
                    + features.lowMid
                    + features.sceneMid
                    + features.vocal
                    + features.treble
            ) / 5
        }
        return Double(min(max(value, 0), 1))
    }
}

struct StageFoliaSceneProfile: Equatable, Sendable {
    let sourceMode: String
    let backend: StageLyricsRenderingBackend
    let audioFocus: StageFoliaAudioFocus
    let enterDuration: TimeInterval
    let exitDuration: TimeInterval
    let audioMovesCamera: Bool
}

extension StageLyricsVisualMode {
    var foliaSourceMode: String {
        switch self {
        case .automatic:
            "automatic"
        case .flowingLine:
            "classic"
        case .depthStack:
            "cadenza"
        case .cloudSteps:
            "partita"
        case .editorialField:
            "fume"
        case .chorusChat:
            "cappella"
        case .cinematicSplit:
            "tilt"
        case .orbitArc:
            "claddagh"
        case .posterRail:
            "monet"
        case .pendulumWheel:
            "pendolo"
        case .dioramaStage:
            "diorama"
        case .foldingVerse:
            "gmgn-folding-verse"
        }
    }

    var renderingBackend: StageLyricsRenderingBackend {
        self == .dioramaStage ? .metal : .swiftUI
    }

    var foliaProfile: StageFoliaSceneProfile {
        let focus: StageFoliaAudioFocus = switch self {
        case .automatic:
            .fullSpectrum
        case .flowingLine:
            .vocalAndTreble
        case .depthStack:
            .vocal
        case .cloudSteps:
            .midAndVocal
        case .editorialField:
            .lowMidAndVocal
        case .chorusChat:
            .vocalAndOnset
        case .cinematicSplit:
            .bassAndVocal
        case .orbitArc:
            .midAndTreble
        case .posterRail:
            .lowMidAndMid
        case .pendulumWheel:
            .bassAndBeat
        case .dioramaStage:
            .fullSpectrum
        case .foldingVerse:
            .vocalAndOnset
        }
        let durations: (TimeInterval, TimeInterval) = switch self {
        case .cloudSteps:
            (0.5, 0.3)
        case .editorialField:
            (0.44, 0.3)
        case .dioramaStage:
            (TimeInterval(StageDioramaTransition.duration), 0.8)
        case .foldingVerse:
            (
                StageLyricFoldSceneModel.transitionDuration,
                StageLyricFoldSceneModel.transitionDuration
            )
        default:
            (0.4, 0.22)
        }
        return StageFoliaSceneProfile(
            sourceMode: foliaSourceMode,
            backend: renderingBackend,
            audioFocus: focus,
            enterDuration: durations.0,
            exitDuration: durations.1,
            audioMovesCamera: false
        )
    }
}

struct StageAIWordColor: Codable, Equatable, Sendable {
    let word: String
    let colorHex: String

    enum CodingKeys: String, CodingKey {
        case word
        case colorHex = "color"
    }
}

struct StageAITheme: Codable, Equatable, Sendable {
    let name: String
    let description: String?
    let backgroundHex: String
    let primaryHex: String
    let accentHex: String
    let secondaryHex: String
    let wordColors: [StageAIWordColor]

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case backgroundHex = "backgroundColor"
        case primaryHex = "primaryColor"
        case accentHex = "accentColor"
        case secondaryHex = "secondaryColor"
        case wordColors
    }
}

struct StageAIDualTheme: Codable, Equatable, Sendable {
    let light: StageAITheme
    let dark: StageAITheme
}

struct StageAIThemeSanitizer: Sendable {
    private static let fallbackLight = StageAITheme(
        name: "晨光",
        description: nil,
        backgroundHex: "#f8fafc",
        primaryHex: "#111827",
        accentHex: "#087ea4",
        secondaryHex: "#475569",
        wordColors: []
    )
    private static let fallbackDark = StageAITheme(
        name: "夜航",
        description: nil,
        backgroundHex: "#080d18",
        primaryHex: "#f8fafc",
        accentHex: "#38bdf8",
        secondaryHex: "#cbd5e1",
        wordColors: []
    )

    func sanitize(_ themes: StageAIDualTheme) -> StageAIDualTheme {
        StageAIDualTheme(
            light: sanitize(themes.light, fallback: Self.fallbackLight),
            dark: sanitize(themes.dark, fallback: Self.fallbackDark)
        )
    }

    private func sanitize(
        _ theme: StageAITheme,
        fallback: StageAITheme
    ) -> StageAITheme {
        let background = Self.normalizedHex(theme.backgroundHex)
            ?? fallback.backgroundHex
        let primary = Self.readableColor(
            theme.primaryHex,
            over: background,
            fallback: fallback.primaryHex,
            minimumContrast: 4.5
        )
        let secondary = Self.readableColor(
            theme.secondaryHex,
            over: background,
            fallback: fallback.secondaryHex,
            minimumContrast: 4.5
        )
        let accent = Self.readableColor(
            theme.accentHex,
            over: background,
            fallback: fallback.accentHex,
            minimumContrast: 2.2
        )
        let wordColors: [StageAIWordColor] = theme.wordColors
            .prefix(20)
            .compactMap { item -> StageAIWordColor? in
            let word = item.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty,
                  let color = Self.normalizedHex(item.colorHex)
            else {
                return nil
            }
            return StageAIWordColor(word: word, colorHex: color)
            }

        return StageAITheme(
            name: theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty ?? fallback.name,
            description: theme.description?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).nonEmpty,
            backgroundHex: background,
            primaryHex: primary,
            accentHex: accent,
            secondaryHex: secondary,
            wordColors: wordColors
        )
    }

    static func normalizedHex(_ source: String) -> String? {
        var value = source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.allSatisfy(\.isHexDigit) else {
            return nil
        }
        switch value.count {
        case 3:
            return "#" + value.map { "\($0)\($0)" }.joined()
        case 6:
            return "#" + value
        default:
            return nil
        }
    }

    static func contrastRatio(
        foregroundHex: String,
        backgroundHex: String
    ) -> Double {
        guard let foreground = rgb(foregroundHex),
              let background = rgb(backgroundHex)
        else {
            return 1
        }
        let foregroundLuminance = relativeLuminance(foreground)
        let backgroundLuminance = relativeLuminance(background)
        return (max(foregroundLuminance, backgroundLuminance) + 0.05)
            / (min(foregroundLuminance, backgroundLuminance) + 0.05)
    }

    static func rgbVector(_ source: String) -> SIMD3<Float>? {
        guard let components = rgb(source) else {
            return nil
        }
        return SIMD3<Float>(
            Float(components.0),
            Float(components.1),
            Float(components.2)
        )
    }

    private static func readableColor(
        _ source: String,
        over background: String,
        fallback: String,
        minimumContrast: Double
    ) -> String {
        guard let normalized = normalizedHex(source),
              contrastRatio(
                  foregroundHex: normalized,
                  backgroundHex: background
              ) >= minimumContrast
        else {
            return fallback
        }
        return normalized
    }

    private static func rgb(_ source: String) -> (Double, Double, Double)? {
        guard let normalized = normalizedHex(source) else {
            return nil
        }
        let value = String(normalized.dropFirst())
        guard let red = Int(value.prefix(2), radix: 16),
              let green = Int(value.dropFirst(2).prefix(2), radix: 16),
              let blue = Int(value.dropFirst(4).prefix(2), radix: 16)
        else {
            return nil
        }
        return (
            Double(red) / 255,
            Double(green) / 255,
            Double(blue) / 255
        )
    }

    private static func relativeLuminance(
        _ color: (Double, Double, Double)
    ) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.0)
            + 0.7152 * linear(color.1)
            + 0.0722 * linear(color.2)
    }
}

struct StageLyricKeywordColorResolver: Sendable {
    private let entries: [StageAIWordColor]

    init(theme: StageAITheme) {
        entries = theme.wordColors.sorted {
            $0.word.count > $1.word.count
        }
    }

    func colorHex(for text: String) -> String? {
        let normalizedText = text.lowercased()
        for entry in entries {
            let keyword = entry.word.lowercased()
            if keyword.containsCJK || normalizedText.containsCJK {
                if normalizedText.contains(keyword) {
                    return entry.colorHex
                }
            } else if containsLatinWord(keyword, in: normalizedText) {
                return entry.colorHex
            }
        }
        return nil
    }

    private func containsLatinWord(_ keyword: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: keyword)
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_])\#(escaped)(?![\p{L}\p{N}_])"#,
            options: [.caseInsensitive]
        ) else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return expression.firstMatch(in: text, range: range) != nil
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    var containsCJK: Bool {
        contains { StageLyricTokenization.isCJK($0) }
    }
}
