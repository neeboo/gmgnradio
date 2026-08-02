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

    static func load(from defaults: UserDefaults = .standard) -> OrbAppearance {
        guard defaults.object(forKey: Keys.red) != nil else {
            return .default
        }
        return OrbAppearance(
            red: clampedColor(defaults.float(forKey: Keys.red)),
            green: clampedColor(defaults.float(forKey: Keys.green)),
            blue: clampedColor(defaults.float(forKey: Keys.blue)),
            flowIntensity: clampedIntensity(
                defaults.float(forKey: Keys.flowIntensity)
            )
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(Self.clampedColor(red), forKey: Keys.red)
        defaults.set(Self.clampedColor(green), forKey: Keys.green)
        defaults.set(Self.clampedColor(blue), forKey: Keys.blue)
        defaults.set(
            Self.clampedIntensity(flowIntensity),
            forKey: Keys.flowIntensity
        )
        NotificationCenter.default.post(
            name: .orbAppearanceDidChange,
            object: defaults
        )
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
