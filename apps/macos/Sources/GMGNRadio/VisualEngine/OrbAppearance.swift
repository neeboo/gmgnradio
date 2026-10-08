import Foundation
import simd

struct OrbAppearance: Equatable, Sendable {
    private enum Keys {
        static let red = "orb.appearance.red"
        static let green = "orb.appearance.green"
        static let blue = "orb.appearance.blue"
        static let flowIntensity = "orb.appearance.flow-intensity"
    }

    static let `default` = OrbAppearance(
        red: 0.16,
        green: 0.62,
        blue: 1,
        flowIntensity: 0.82
    )

    var red: Float
    var green: Float
    var blue: Float
    var flowIntensity: Float

    var metalColor: SIMD4<Float> {
        SIMD4(red, green, blue, 1)
    }

    @MainActor static func load(from defaults: UserDefaults = .standard, settings: RustProductSettingsClient = .shared) -> OrbAppearance {
        settings.bootstrap(legacy: RustProductSettingsClient.legacySnapshot(defaults))
        guard let values=settings.confirmed?.values else { return .default }
        return OrbAppearance(red: Float(values.orbRed), green: Float(values.orbGreen), blue: Float(values.orbBlue), flowIntensity: Float(values.orbFlowIntensity))
    }

    @MainActor func save(to defaults: UserDefaults = .standard, settings: RustProductSettingsClient = .shared) async throws -> OrbAppearance {
        _ = try await settings.apply(["orbRed":red,"orbGreen":green,"orbBlue":blue,"orbFlowIntensity":flowIntensity])
        NotificationCenter.default.post(
            name: .orbAppearanceDidChange,
            object: defaults
        )
        return Self.load(from: defaults, settings: settings)
    }

    private static func clampedColor(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    private static func clampedIntensity(_ value: Float) -> Float {
        min(max(value, 0.35), 1.5)
    }
}

extension Notification.Name {
    static let orbAppearanceDidChange = Notification.Name(
        "ai.gmgn.radio.orb-appearance-did-change"
    )
}
