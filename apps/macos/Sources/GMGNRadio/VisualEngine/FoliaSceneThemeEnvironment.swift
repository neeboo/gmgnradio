import SwiftUI

// SwiftUI theme bridge for the Folia-derived scene runtime.
// Modified for gmgn radio on 2026-07-31 under GNU AGPL v3.

extension StageAITheme {
    static let gmgnDefaultDark = StageAITheme(
        name: "夜航",
        description: nil,
        backgroundHex: "#080d18",
        primaryHex: "#e8f1ff",
        accentHex: "#38bdf8",
        secondaryHex: "#a78bfa",
        wordColors: []
    )

    var backgroundColor: Color {
        Color(stageHex: backgroundHex, fallback: (0.03, 0.05, 0.09))
    }

    var primaryColor: Color {
        Color(stageHex: primaryHex, fallback: (0.91, 0.95, 1))
    }

    var accentColor: Color {
        Color(stageHex: accentHex, fallback: (0.22, 0.74, 0.97))
    }

    var secondaryColor: Color {
        Color(stageHex: secondaryHex, fallback: (0.65, 0.55, 0.98))
    }

    func semanticColor(for text: String) -> Color? {
        guard let value = StageLyricKeywordColorResolver(theme: self)
            .colorHex(for: text)
        else {
            return nil
        }
        return Color(stageHex: value, fallback: (0.22, 0.74, 0.97))
    }
}

private struct StageFoliaThemeKey: EnvironmentKey {
    static let defaultValue = StageAITheme.gmgnDefaultDark
}

extension EnvironmentValues {
    var stageFoliaTheme: StageAITheme {
        get { self[StageFoliaThemeKey.self] }
        set { self[StageFoliaThemeKey.self] = newValue }
    }
}

private extension Color {
    init(
        stageHex source: String,
        fallback: (Double, Double, Double)
    ) {
        guard let vector = StageAIThemeSanitizer.rgbVector(source) else {
            self.init(
                red: fallback.0,
                green: fallback.1,
                blue: fallback.2
            )
            return
        }
        self.init(
            red: Double(vector.x),
            green: Double(vector.y),
            blue: Double(vector.z)
        )
    }
}
