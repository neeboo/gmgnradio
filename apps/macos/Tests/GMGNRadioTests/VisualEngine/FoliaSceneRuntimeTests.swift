import Foundation
import Testing
@testable import GMGNRadio

@Test
func lyricSceneRegistryIncludesTheGMGNFoldingVerseMode() {
    let modes = StageLyricsVisualMode.playbackModes

    #expect(modes.count == 11)
    #expect(modes.map(\.foliaSourceMode) == [
        "classic",
        "cadenza",
        "partita",
        "fume",
        "cappella",
        "tilt",
        "claddagh",
        "monet",
        "pendolo",
        "diorama",
        "gmgn-folding-verse",
    ])
    #expect(modes.map(\.displayName) == [
        "流光",
        "心象",
        "云阶",
        "浮名",
        "群唱",
        "倾诉",
        "回环",
        "莫奈",
        "时计",
        "镜台",
        "折章",
    ])
}

@Test
func foliaSceneRegistrySeparatesSwiftUIAndMetalScenes() {
    #expect(StageLyricsVisualMode.flowingLine.renderingBackend == .swiftUI)
    #expect(StageLyricsVisualMode.posterRail.renderingBackend == .swiftUI)
    #expect(StageLyricsVisualMode.dioramaStage.renderingBackend == .metal)
}

@Test
func aiThemeSanitizerNormalizesColorsAndRepairsUnreadableText() {
    let raw = StageAIDualTheme(
        light: StageAITheme(
            name: "雾白清晨",
            description: "我在潮湿晨光里慢慢醒来",
            backgroundHex: "#eef2f3",
            primaryHex: "#f0f0f0",
            accentHex: "#3af",
            secondaryHex: "invalid",
            wordColors: [
                StageAIWordColor(word: "雨", colorHex: "#36c"),
            ]
        ),
        dark: StageAITheme(
            name: "雨夜深蓝",
            description: "我听见霓虹落进安静的水面",
            backgroundHex: "#080d18",
            primaryHex: "#e8f1ff",
            accentHex: "#6ac8ff",
            secondaryHex: "#9ca8bc",
            wordColors: [
                StageAIWordColor(word: "雨", colorHex: "#68b8ff"),
            ]
        )
    )

    let sanitized = StageAIThemeSanitizer().sanitize(raw)

    #expect(sanitized.light.accentHex == "#33aaff")
    #expect(sanitized.light.secondaryHex != "invalid")
    #expect(
        StageAIThemeSanitizer.contrastRatio(
            foregroundHex: sanitized.light.primaryHex,
            backgroundHex: sanitized.light.backgroundHex
        ) >= 4.5
    )
    #expect(sanitized.dark.wordColors.first?.colorHex == "#68b8ff")
}

@Test
func keywordColorsPreferTheLongestSemanticMatch() {
    let theme = StageAITheme(
        name: "雨夜",
        description: nil,
        backgroundHex: "#080d18",
        primaryHex: "#e8f1ff",
        accentHex: "#6ac8ff",
        secondaryHex: "#9ca8bc",
        wordColors: [
            StageAIWordColor(word: "雨", colorHex: "#5599ff"),
            StageAIWordColor(word: "城市的雨", colorHex: "#ff6688"),
            StageAIWordColor(word: "night", colorHex: "#bb88ff"),
        ]
    )
    let resolver = StageLyricKeywordColorResolver(theme: theme)

    #expect(resolver.colorHex(for: "城市的雨") == "#ff6688")
    #expect(resolver.colorHex(for: "night") == "#bb88ff")
    #expect(resolver.colorHex(for: "nightly") == nil)
}

@Test
func darkAIThemeMapsAllFourSemanticColorsIntoTheStagePalette() {
    let theme = StageAITheme(
        name: "深海霓虹",
        description: nil,
        backgroundHex: "#081020",
        primaryHex: "#dcecff",
        accentHex: "#44ccff",
        secondaryHex: "#7a88aa",
        wordColors: []
    )

    let palette = StageVisualPalette(theme: theme)

    #expect(palette.background == SIMD3<Float>(8 / 255, 16 / 255, 32 / 255))
    #expect(palette.primary == SIMD3<Float>(68 / 255, 204 / 255, 1))
    #expect(palette.secondary == SIMD3<Float>(220 / 255, 236 / 255, 1))
    #expect(palette.tertiary == SIMD3<Float>(122 / 255, 136 / 255, 170 / 255))
}

@Test
@MainActor
func lyricThemeResultIsAppliedOnlyToTheTrackThatRequestedIt() {
    let store = StageLyricsStore()
    store.publish(
        MusicLyrics(
            original: "[00:00.00]第一首",
            translation: nil
        ),
        trackID: "track-a"
    )
    let theme = StageAITheme(
        name: "夜雨",
        description: nil,
        backgroundHex: "#080d18",
        primaryHex: "#e8f1ff",
        accentHex: "#6ac8ff",
        secondaryHex: "#9ca8bc",
        wordColors: []
    )

    #expect(!store.apply(theme: theme, requestedForTrackID: "track-b"))
    #expect(store.activeTheme == nil)
    #expect(store.apply(theme: theme, requestedForTrackID: "track-a"))
    #expect(store.activeTheme == theme)

    store.clear()
    #expect(store.activeTheme == nil)
}

@Test
func dioramaTransitionKeepsTheIncomingSceneBeyondTheFogPlane() {
    let offset = StageDioramaTransition.pickOffset(
        seed: "track-city-pop",
        epoch: 3
    )

    let length = sqrt(
        offset.x * offset.x
            + offset.y * offset.y
            + offset.z * offset.z
    )
    #expect(abs(length - 46) < 0.001)
    #expect(offset.z < 0)
}

@Test
func dioramaCameraFlightUsesAContinuousEasedBezierArc() {
    let from = SIMD3<Float>(0, 0, 0)
    let to = SIMD3<Float>(18, 8, -42)
    let control = StageDioramaTransition.bezierControl(
        from: from,
        to: to,
        seed: "track-city-pop",
        epoch: 3
    )

    #expect(
        StageDioramaTransition.bezierArc(
            from: from,
            control: control,
            to: to,
            progress: 0
        ) == from
    )
    #expect(
        StageDioramaTransition.bezierArc(
            from: from,
            control: control,
            to: to,
            progress: 1
        ) == to
    )
    #expect(StageDioramaTransition.ease(-1) == 0)
    #expect(StageDioramaTransition.ease(2) == 1)
    #expect(StageDioramaTransition.ease(0.5) == 0.5)
}

@Test
func everyFoliaSceneDeclaresItsOwnAudioAndCameraBehavior() {
    let profiles = StageLyricsVisualMode.playbackModes.map(\.foliaProfile)

    #expect(profiles.map(\.audioFocus) == [
        .vocalAndTreble,
        .vocal,
        .midAndVocal,
        .lowMidAndVocal,
        .vocalAndOnset,
        .bassAndVocal,
        .midAndTreble,
        .lowMidAndMid,
        .bassAndBeat,
        .fullSpectrum,
        .vocalAndOnset,
    ])
    #expect(profiles.filter { $0.backend == .metal }.count == 1)
    #expect(profiles.allSatisfy { !$0.audioMovesCamera })
}
