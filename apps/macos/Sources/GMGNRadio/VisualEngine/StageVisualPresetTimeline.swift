import Combine
import Foundation

enum StageVisualMood: String, Codable, CaseIterable, Sendable {
    case afterglow
    case liquid
    case pulse
}

enum StageVisualTopology: Equatable, Sendable {
    case flowingCanvas
    case orbitalShell
    case openRibbon
}

enum StagePointCloudChoice: String, CaseIterable, Equatable, Sendable {
    case automatic
    case flowingCanvas
    case orbitalShell
    case openRibbon
    case albumRelief = "vinylRecord"
    case galaxyField
    case tunnel
    case void

    var mood: StageVisualMood? {
        switch self {
        case .automatic:
            nil
        case .flowingCanvas:
            .afterglow
        case .orbitalShell:
            .liquid
        case .openRibbon:
            .pulse
        case .albumRelief, .galaxyField, .tunnel, .void:
            nil
        }
    }

    var title: String {
        switch self {
        case .automatic:
            "自动"
        case .flowingCanvas:
            "流幕"
        case .orbitalShell:
            "星球"
        case .openRibbon:
            "光带"
        case .albumRelief:
            "封面"
        case .galaxyField:
            "星河"
        case .tunnel:
            "滚筒"
        case .void:
            "留白"
        }
    }

    var symbolName: String {
        switch self {
        case .automatic:
            "sparkles"
        case .flowingCanvas:
            "wave.3.right"
        case .orbitalShell:
            "circle.hexagongrid"
        case .openRibbon:
            "point.3.connected.trianglepath.dotted"
        case .albumRelief:
            "photo.on.rectangle.angled"
        case .galaxyField:
            "sparkles.rectangle.stack"
        case .tunnel:
            "circle.circle"
        case .void:
            "circle.slash"
        }
    }

    func resolvedPresetFrame(
        automatic: StageVisualPresetFrame
    ) -> StageVisualPresetFrame {
        switch self {
        case .automatic:
            automatic
        case .flowingCanvas:
            StageVisualPresetFrame(
                weights: SIMD3<Float>(1, 0, 0),
                composition: 0
            )
        case .orbitalShell:
            StageVisualPresetFrame(
                weights: SIMD3<Float>(0, 1, 0),
                composition: 0.24
            )
        case .openRibbon:
            StageVisualPresetFrame(
                weights: SIMD3<Float>(0, 0, 1),
                composition: 0
            )
        case .albumRelief:
            StageVisualPresetFrame(
                weights: SIMD3<Float>(1, 0, 0),
                composition: 2
            )
        case .galaxyField:
            StageVisualPresetFrame(
                weights: SIMD3<Float>(0, 0, 1),
                composition: 2
            )
        case .tunnel:
            StageVisualPresetFrame(
                weights: SIMD3<Float>(0, 1, 0),
                composition: 2
            )
        case .void:
            StageVisualPresetFrame(
                weights: .zero,
                composition: 0
            )
        }
    }

    var allowsAutoOrbit: Bool {
        self != .albumRelief
    }
}

struct StagePointLayerPolicy: Equatable, Sendable {
    let primaryVisibility: Float
    let ambientVisibility: Float

    static func resolve(
        choice: StagePointCloudChoice,
        videoActive: Bool
    ) -> Self {
        if choice == .void {
            return Self(primaryVisibility: 0, ambientVisibility: 0)
        }

        if choice == .albumRelief {
            return Self(
                primaryVisibility: videoActive ? 0.66 : 1,
                ambientVisibility: videoActive ? 0.72 : 0.52
            )
        }

        if choice == .galaxyField {
            return Self(
                primaryVisibility: videoActive ? 0.14 : 0.42,
                ambientVisibility: 1.08
            )
        }

        if videoActive {
            let primaryVisibility: Float = switch choice {
            case .automatic:
                0.36
            case .flowingCanvas, .orbitalShell:
                0.54
            case .openRibbon:
                0.48
            case .tunnel:
                0.46
            case .albumRelief, .galaxyField, .void:
                0
            }
            return Self(
                primaryVisibility: primaryVisibility,
                ambientVisibility: 1
            )
        }

        return Self(primaryVisibility: 1, ambientVisibility: 0.72)
    }
}

struct StageVisualPresetFrame: Equatable, Sendable {
    var weights: SIMD3<Float>
    var composition: Float = 0

    var dominantTopology: StageVisualTopology {
        if weights.z >= weights.x, weights.z >= weights.y {
            return .openRibbon
        }
        if weights.y >= weights.x {
            return .orbitalShell
        }
        return .flowingCanvas
    }

    static func forMood(_ mood: StageVisualMood) -> Self {
        switch mood {
        case .afterglow:
            Self(weights: SIMD3<Float>(1, 0, 0), composition: 0.82)
        case .liquid:
            Self(weights: SIMD3<Float>(0, 1, 0), composition: 0.24)
        case .pulse:
            Self(weights: SIMD3<Float>(0, 0, 1), composition: 0.64)
        }
    }
}

struct StageVisualPalette: Equatable, Sendable {
    let primary: SIMD3<Float>
    let secondary: SIMD3<Float>
    let tertiary: SIMD3<Float>
    let background: SIMD3<Float>

    init(
        primary: SIMD3<Float>,
        secondary: SIMD3<Float>,
        tertiary: SIMD3<Float>? = nil,
        background: SIMD3<Float>
    ) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary ?? secondary
        self.background = background
    }

    init(theme: StageAITheme) {
        primary = StageAIThemeSanitizer.rgbVector(theme.accentHex)
            ?? Self.aqua.primary
        secondary = StageAIThemeSanitizer.rgbVector(theme.primaryHex)
            ?? Self.aqua.secondary
        tertiary = StageAIThemeSanitizer.rgbVector(theme.secondaryHex)
            ?? Self.aqua.tertiary
        background = StageAIThemeSanitizer.rgbVector(theme.backgroundHex)
            ?? Self.aqua.background
    }

    static let amber = Self(
        primary: SIMD3<Float>(1, 0.34, 0.04),
        secondary: SIMD3<Float>(1, 0.74, 0.18),
        background: SIMD3<Float>(0.014, 0.008, 0.007)
    )
    static let aqua = Self(
        primary: SIMD3<Float>(0.00, 0.82, 0.76),
        secondary: SIMD3<Float>(0.10, 0.42, 1.00),
        background: SIMD3<Float>(0.005, 0.012, 0.016)
    )
    static let indigo = Self(
        primary: SIMD3<Float>(0.28, 0.34, 1.00),
        secondary: SIMD3<Float>(0.68, 0.16, 0.96),
        background: SIMD3<Float>(0.007, 0.006, 0.018)
    )
    static let rose = Self(
        primary: SIMD3<Float>(1.00, 0.16, 0.46),
        secondary: SIMD3<Float>(1.00, 0.52, 0.68),
        background: SIMD3<Float>(0.015, 0.006, 0.013)
    )
    static let emerald = Self(
        primary: SIMD3<Float>(0.04, 0.84, 0.38),
        secondary: SIMD3<Float>(0.18, 0.94, 0.72),
        background: SIMD3<Float>(0.005, 0.014, 0.010)
    )
    static let silver = Self(
        primary: SIMD3<Float>(0.62, 0.70, 0.82),
        secondary: SIMD3<Float>(0.90, 0.94, 1.00),
        background: SIMD3<Float>(0.010, 0.012, 0.018)
    )

    static func forMood(_ mood: StageVisualMood) -> Self {
        switch mood {
        case .afterglow:
            .amber
        case .liquid:
            .aqua
        case .pulse:
            .indigo
        }
    }

    static func blended(for weights: SIMD3<Float>) -> Self {
        let amber = Self.amber
        let aqua = Self.aqua
        let indigo = Self.indigo
        return Self(
            primary: amber.primary * weights.x
                + aqua.primary * weights.y
                + indigo.primary * weights.z,
            secondary: amber.secondary * weights.x
                + aqua.secondary * weights.y
                + indigo.secondary * weights.z,
            tertiary: amber.tertiary * weights.x
                + aqua.tertiary * weights.y
                + indigo.tertiary * weights.z,
            background: amber.background * weights.x
                + aqua.background * weights.y
                + indigo.background * weights.z
        )
    }

    static func interpolated(
        from start: Self,
        to end: Self,
        progress: Float
    ) -> Self {
        let amount = min(max(progress, 0), 1)
        return Self(
            primary: start.primary
                + (end.primary - start.primary) * amount,
            secondary: start.secondary
                + (end.secondary - start.secondary) * amount,
            tertiary: start.tertiary
                + (end.tertiary - start.tertiary) * amount,
            background: start.background
                + (end.background - start.background) * amount
        )
    }
}

@MainActor
final class StageVisualDirectionStore: ObservableObject {
    private let settings: RustProductSettingsClient
    private var settingsLoad: Task<Void, Error>?
    nonisolated(unsafe) private var settingsObserver: NSObjectProtocol?
    @Published private(set) var settingsError: String?
    @Published private(set) var currentMood: StageVisualMood?
    @Published private(set) var currentPalette: StageVisualPalette?
    @Published private(set) var currentPointCloudChoice:
        StagePointCloudChoice = .automatic
    @Published private(set) var currentIntensity: Float = 1
    @Published private(set) var transitionDuration: TimeInterval = 2.4
    @Published private(set) var particleSizeMultiplier: Float = 1

    init(defaults: UserDefaults = .standard, settings: RustProductSettingsClient = .shared) {
        self.settings = settings
        let legacy = RustProductSettingsClient.stageLegacySnapshot(defaults)
        settingsObserver = NotificationCenter.default.addObserver(forName: .init("gmgnProductSettingsConfirmed"), object: settings, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.projectConfirmed() }
        }
        projectConfirmed()
        settingsLoad = Task { [weak self] in
            guard let self else { return }
            do { _ = try await settings.importStageLegacy(legacy: legacy); projectConfirmed() }
            catch { settingsError = "舞台设置未能确认。"; throw error }
        }
    }

    deinit { if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) } }

    func awaitSettingsReady() async throws { try await settingsLoad?.value }

    private func projectConfirmed() {
        guard let values = settings.confirmed?.values,
              let choice = StagePointCloudChoice(rawValue: values.stagePointCloudChoice) else { return }
        if currentPointCloudChoice != choice { transitionDuration = 1.8 }
        currentPointCloudChoice = choice
        particleSizeMultiplier = Float(values.stageParticleSizeMultiplier)
    }

    func update(_ mood: StageVisualMood?) {
        currentMood = mood
        currentPalette = mood.map(StageVisualPalette.forMood)
        currentIntensity = 1
        transitionDuration = 2.4
    }

    func update(_ cue: ProgramVisualCue) {
        currentMood = cue.mood
        currentPalette = cue.palette
        currentIntensity = cue.intensity
        transitionDuration = cue.transitionDuration
    }

    func selectPointCloud(_ choice: StagePointCloudChoice) {
        Task { do { try await selectPointCloud(rawValue: choice.rawValue) }
            catch { settingsError = "点阵选择未能确认。" } }
    }

    func setParticleSizeMultiplier(_ value: Float) {
        Task { do { try await setParticleSizeMultiplier(rawValue: Double(value)) }
            catch { settingsError = "粒径设置未能确认。" } }
    }

    func selectPointCloud(rawValue: String) async throws {
        try await awaitSettingsReady()
        _ = try await settings.selectPointCloud(raw: rawValue)
        projectConfirmed(); settingsError = nil
    }

    func setParticleSizeMultiplier(rawValue: Double) async throws {
        try await awaitSettingsReady()
        _ = try await settings.setParticleSizeMultiplier(rawValue)
        projectConfirmed(); settingsError = nil
    }
}

struct StageVisualPresetTimeline: Sendable {
    private static let presetCount = 6

    let presetDuration: Float
    let transitionDuration: Float

    init(
        presetDuration: Float = 24,
        transitionDuration: Float = 4
    ) {
        self.presetDuration = max(presetDuration, 1)
        self.transitionDuration = min(
            max(transitionDuration, 0),
            self.presetDuration
        )
    }

    func sample(at time: Float) -> StageVisualPresetFrame {
        let safeTime = max(time, 0)
        let cycleIndex = Int(floor(safeTime / presetDuration))
        let currentIndex = cycleIndex % Self.presetCount
        let nextIndex = (currentIndex + 1) % Self.presetCount
        let elapsed = safeTime.truncatingRemainder(dividingBy: presetDuration)
        let transitionStart = presetDuration - transitionDuration
        let blend: Float

        if transitionDuration > 0, elapsed > transitionStart {
            blend = (elapsed - transitionStart) / transitionDuration
        } else {
            blend = 0
        }

        let current = Self.frame(at: currentIndex)
        let next = Self.frame(at: nextIndex)
        return StageVisualPresetFrame(
            weights: current.weights
                + (next.weights - current.weights) * blend,
            composition: current.composition
                + (next.composition - current.composition) * blend
        )
    }

    private static func frame(at index: Int) -> StageVisualPresetFrame {
        var weights = SIMD3<Float>(repeating: 0)
        let topologyIndex = index % 3
        weights[topologyIndex] = 1
        let composition: Float
        if index >= 3 {
            composition = 1
        } else if topologyIndex == 1 {
            composition = 0.24
        } else {
            composition = 0
        }
        return StageVisualPresetFrame(
            weights: weights,
            composition: composition
        )
    }
}
