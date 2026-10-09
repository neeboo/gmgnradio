// Gate: the settings snapshot must not rebuild the motion list per row.
//
// 2026-10-09 regression (build 227): `UnityPresenceSettingsBridge.snapshot`
// answered each row's `selectable` flag with `canSelectMotion(motion.id)`, and
// that predicate resolves the id by rebuilding `model.availableMotions` — a
// filtered copy of every motion, with String/URL/ARC traffic. One snapshot was
// therefore O(rows²) copies on the host's main thread at ~20 Hz. `sample` on
// the real machine put 57 % of a 92 ms frame in
// `settingsSnapshot` → `presenceSettings.snapshot` → `motionSelectionRefusal`
// → `availableMotions`, and the renderer's asset load stalled behind the same
// main thread (`phase=prepare` never reached `activate`).
//
// The flag has to keep meaning exactly what `motionSelectionRefusal` answers —
// a row drawn selectable must never be refused. This gate pins the fix in both
// directions: the projection must hoist the one row-independent refusal and
// the single motion-list read, and it must still derive `selectable` from
// them. The negative control below is the pre-fix row, which must go red.
import Foundation

let path = "apps/macos/UnityHost/UnityPresenceSettingsBridge.swift"
let source = try String(contentsOfFile: path, encoding: .utf8)

/// The body of the `"motions": ...` projection inside `snapshot`.
func motionsProjection(_ text: String) -> String {
    guard let start = text.range(of: "\"motions\": ", range: text.range(of: "var snapshot:")!.upperBound..<text.endIndex) else {
        fatalError("snapshot has no motions projection")
    }
    var depth = 0
    var opened = false
    for index in text[start.lowerBound...].indices {
        switch text[index] {
        case "[", "(": depth += 1
        case "{": depth += 1; opened = true
        case "]", ")": depth -= 1
        case "}": depth -= 1
        default: break
        }
        if opened && depth == 0 { return String(text[start.lowerBound...index]) }
    }
    fatalError("unbalanced motions projection")
}

/// Checks that must hold for the projection; each returns a failure reason or nil.
func violations(_ text: String) -> [String] {
    let snapshot = String(text[text.range(of: "var snapshot:")!.lowerBound...])
    let projection = motionsProjection(snapshot)
    var failures: [String] = []
    if projection.contains("canSelectMotion(") {
        failures.append("the per-row map asks canSelectMotion, which rebuilds availableMotions for every row")
    }
    if projection.contains("availableMotions") {
        failures.append("the per-row map reads availableMotions; the list must be read once per snapshot")
    }
    if !snapshot.contains("let motions = model.availableMotions") {
        failures.append("snapshot does not hoist exactly one `let motions = model.availableMotions`")
    }
    let hoists = snapshot.components(separatedBy: "let refusal = selectionRefusalCode").count - 1
    if hoists != 1 {
        failures.append("snapshot must hoist `let refusal = selectionRefusalCode` once (found \(hoists))")
    }
    if !projection.contains("\"selectable\": refusal == nil && compatible") {
        failures.append("selectable must be derived from the hoisted refusal plus the row's own compatibility")
    }
    return failures
}

let check = violations(source)
if !check.isEmpty {
    FileHandle.standardError.write(Data(("presence snapshot projection gate: FAIL\n  - " + check.joined(separator: "\n  - ") + "\n").utf8))
    exit(1)
}

// Negative control: the code as it shipped in build 227. The gate must reject it.
let preFix = """
    var snapshot: [String: Any] {
        let orb = model.orbAppearance
        return ["motions": model.availableMotions.map { motion in
            let compatible = model.motionCompatibility(motion) == .compatible
            return ["id": motion.id, "compatible": compatible, "selectable": canSelectMotion(motion.id)] as [String: Any]
        }]
    }
"""
if violations(preFix).isEmpty {
    FileHandle.standardError.write(Data("presence snapshot projection gate: negative control passed but must fail\n".utf8))
    exit(1)
}

// Positive control: the fixed shape must be accepted.
let fixed = """
    var snapshot: [String: Any] {
        let motions = model.availableMotions
        let refusal = selectionRefusalCode
        return ["motions": motions.map { motion in
            let compatibility = model.motionCompatibility(motion)
            let compatible = compatibility == .compatible
            return ["id": motion.id, "compatible": compatible, "selectable": refusal == nil && compatible] as [String: Any]
        }]
    }
"""
if !violations(fixed).isEmpty {
    FileHandle.standardError.write(Data("presence snapshot projection gate: positive control rejected\n".utf8))
    exit(1)
}

print("presence snapshot projection gate: PASS (one motion-list read per snapshot; selectable still derived from the host refusal predicate)")
