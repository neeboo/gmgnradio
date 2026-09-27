import Foundation

/// Primary browsing category for the reviewed BONES selection.
/// This organizes assets only; it never enables resident activities or claims
/// motion/ground-contact validation. Unknown imports remain unclassified.
enum MotionLibraryCategory: String, CaseIterable, Identifiable, Sendable {
    case life, work, exercise, drama

    var id: String { rawValue }

    var title: String {
        switch self {
        case .life: "生活"
        case .work: "工作"
        case .exercise: "运动"
        case .drama: "戏剧"
        }
    }

    static func category(forMotionID id: String) -> Self? {
        guard id.hasSuffix("-pmx") || id.hasSuffix("-vrm") else { return nil }
        let base = String(id.dropLast(4))
        let arpgPrefix = "gmgn.motion.bones.arpg."
        if base.hasPrefix(arpgPrefix) {
            return arpgCategory(forKey: String(base.dropFirst(arpgPrefix.count)))
        }
        switch base {
        case "gmgn.motion.bones.thinking-loop":
            return .work
        case "gmgn.motion.bones.idle-loop", "gmgn.motion.bones.hold-display",
             "gmgn.motion.bones.chair-sit-loop", "gmgn.motion.bones.cross-legged-loop",
             "gmgn.motion.bones.kneeling-loop", "gmgn.motion.bones.coffee-button":
            return .life
        case "gmgn.motion.bones.walk-loop", "gmgn.motion.bones.jumping-jacks":
            return .exercise
        default:
            return nil
        }
    }

    private static func arpgCategory(forKey key: String) -> Self? {
        switch key {
        case "idle-neutral",
             "idle-staggered",
             "pickup-standing",
             "pickup-crouched",
             "pickup-walking",
             "pickup-jogging",
             "pickup-crouch-walking",
             "pickup-front-high",
             "pickup-side-high",
             "pickup-front-medium",
             "interact-door-open",
             "interact-door-pass-close",
             "interact-door-pull",
             "interact-door-knock",
             "object-hold-small",
             "object-hold-small-long",
             "object-hold-large",
             "object-switch-hands",
             "place-front-high",
             "place-front-medium",
             "place-front-low",
             "place-side-low":
            return .life
        case "interact-button-high",
             "interact-button-mid":
            return .work
        case "walk-forward-loop",
             "walk-forward-right-loop",
             "walk-right-loop",
             "walk-back-right-loop",
             "walk-backward-loop",
             "walk-back-left-loop",
             "walk-left-loop",
             "walk-forward-left-loop",
             "walk-forward-start",
             "walk-forward-right-start",
             "walk-right-start",
             "walk-back-right-start",
             "walk-backward-start",
             "walk-back-left-start",
             "walk-left-start",
             "walk-forward-left-start",
             "walk-forward-stop",
             "walk-forward-right-stop",
             "walk-right-stop",
             "walk-back-right-stop",
             "walk-backward-stop",
             "walk-back-left-stop",
             "walk-left-stop",
             "walk-forward-left-stop",
             "jog-forward-loop",
             "jog-forward-right-loop",
             "jog-right-loop",
             "jog-back-right-loop",
             "jog-backward-loop",
             "jog-forward-left-loop",
             "jog-left-loop",
             "jog-back-left-loop",
             "jog-forward-start",
             "jog-forward-right-start",
             "jog-right-start",
             "jog-back-right-start",
             "jog-backward-start",
             "jog-forward-left-start",
             "jog-left-start",
             "jog-back-left-start",
             "jog-forward-stop",
             "jog-forward-right-stop",
             "jog-right-stop",
             "jog-back-right-stop",
             "jog-backward-stop",
             "jog-forward-left-stop",
             "jog-left-stop",
             "jog-back-left-stop",
             "sprint-forward-loop",
             "sprint-forward-start",
             "sprint-forward-stop",
             "turn-idle-left-180",
             "turn-idle-left-135",
             "turn-idle-left-90",
             "turn-idle-left-45",
             "turn-idle-right-90",
             "turn-idle-right-180",
             "turn-idle-right-45",
             "turn-idle-right-135",
             "turn-walk-right-90",
             "turn-walk-right-180",
             "turn-walk-left-90",
             "turn-walk-left-180",
             "turn-jog-right-90",
             "turn-jog-right-180",
             "turn-jog-left-90",
             "turn-jog-left-180",
             "arc-walk-loop",
             "arc-walk-start",
             "arc-walk-stop",
             "arc-jog-loop",
             "arc-jog-start",
             "arc-jog-stop",
             "crouch-idle",
             "crouch-forward",
             "crouch-forward-right",
             "crouch-right",
             "crouch-back-right",
             "crouch-backward",
             "crouch-start",
             "crouch-stop",
             "jump-up",
             "jump-forward",
             "jump-right",
             "jump-backward",
             "jump-left",
             "jump-back-left",
             "jump-forward-left",
             "jump-high-up",
             "platform-off-front-50cm",
             "platform-off-back-50cm",
             "platform-off-1m",
             "platform-on-50cm",
             "platform-on-1m",
             "vault-50cm-right",
             "vault-75cm-right",
             "vault-1m-right",
             "vault-1m-left",
             "vault-150cm-right",
             "vault-150cm-left",
             "vault-2m-right",
             "vault-75cm-no-hands",
             "ladder-up-start-symmetric",
             "ladder-up-start-alternating",
             "ladder-down-start",
             "ladder-down-loop",
             "ladder-down-stop",
             "ladder-idle",
             "ladder-step-off",
             "ladder-jump-off",
             "stairs-walk-up-start",
             "stairs-walk-down-loop",
             "stairs-walk-down-stop",
             "stairs-jog-up-start",
             "stairs-jog-down-loop",
             "stairs-jog-down-stop",
             "roll-side-right",
             "roll-side-left",
             "roll-landing-shoulder",
             "roll-long-jump-shoulder",
             "jump-back-right",
             "jump-forward-right":
            return .exercise
        case "idle-alert",
             "alert-enter",
             "dodge-right",
             "dodge-left",
             "dodge-backward",
             "dodge-duck",
             "dodge-up",
             "combat-turn-right-jog",
             "combat-turn-back-jog",
             "attack-straight-punch-combo-a359",
             "attack-straight-punch-combo-a360",
             "attack-straight-punch-combo-a361",
             "attack-straight-punch-combo-a362",
             "hit-air-spin-fall",
             "hit-air-spin-fall-mirror",
             "recovery-faint",
             "recovery-faint-side",
             "recovery-run-fall",
             "recovery-get-up-back",
             "recovery-get-up-side",
             "recovery-get-up-front",
             "recovery-faint-recover-back",
             "recovery-faint-recover-side":
            return .drama
        default:
            return nil
        }
    }
}
