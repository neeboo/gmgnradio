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

// ---------------------------------------------------------------------------
// Second gate: the *pending renderer receipt* marker must be bounded.
//
// `pendingRenderer` is cleared only by the renderer's own `renderer_ack`. On the
// real device the renderer can die, be replaced by a build without the ack, or
// simply never answer — and then every later 选定动作 answered
// `presence_renderer_pending` for the life of the process (2026-10-09). The
// host half is a bounded marker: it is observed in `publish`, it carries the
// wall clock of its first observation, and the refusal predicate abandons it
// before it can refuse a click. The daemon carries the same bound, so an app
// restart cannot resurrect the lock. The negative control is the pre-fix shape.
func pendingBoundViolations(_ text: String) -> [String] {
    var failures: [String] = []
    if !text.contains("static let rendererAckBudget") {
        failures.append("the bridge has no `rendererAckBudget`: a renderer receipt that never came is unbounded")
    }
    if !text.contains("private var pendingSince: Date?") {
        failures.append("`pendingSelection` carries no observation time, so its age cannot be bounded")
    }
    guard let refusal = text.range(of: "var selectionRefusalCode: String? {") else {
        return failures + ["the bridge has no selectionRefusalCode"]
    }
    let body = String(text[refusal.lowerBound...].prefix(600))
    if !body.contains("expireStalePendingRenderer()") {
        failures.append("selectionRefusalCode answers the gate without expiring a stale pending renderer")
    }
    if !text.contains("if pendingSince == nil { pendingSince = Date() }") {
        failures.append("publish() does not record when the pending renderer was first observed")
    }
    return failures
}

let pendingCheck = pendingBoundViolations(source)
if !pendingCheck.isEmpty {
    FileHandle.standardError.write(Data(("presence renderer-pending bound gate: FAIL\n  - " + pendingCheck.joined(separator: "\n  - ") + "\n").utf8))
    exit(1)
}

// Negative control: the pre-fix shape must be rejected.
let pendingPreFix = """
    private var pendingSelection: (revision: UInt64, authorityRevision: Int64)?
    var selectionRefusalCode: String? {
        gate.refusal(isWorking: model.isWorking, hasPendingSelection: pendingSelection != nil)
    }
    private func publish() {
        if let state=selectionAuthority.confirmed,state.pendingRenderer {
            pendingSelection=(runtime.snapshot.revision,state.revision)
        } else { pendingSelection=nil }
    }
"""
if pendingBoundViolations(pendingPreFix).isEmpty {
    FileHandle.standardError.write(Data("presence renderer-pending bound gate: negative control passed but must fail\n".utf8))
    exit(1)
}

// Positive control: the fixed shape must be accepted.
let pendingFixed = """
    private var pendingSelection: (revision: UInt64, authorityRevision: Int64)?
    private var pendingSince: Date?
    static let rendererAckBudget: TimeInterval = 180
    var selectionRefusalCode: String? {
        _ = expireStalePendingRenderer()
        return gate.refusal(isWorking: model.isWorking, hasPendingSelection: pendingSelection != nil)
    }
    private func publish() {
        if let state=selectionAuthority.confirmed,state.pendingRenderer {
            pendingSelection=(runtime.snapshot.revision,state.revision)
            if pendingSince == nil { pendingSince = Date() }
        } else { pendingSelection=nil; pendingSince=nil }
    }
"""
if !pendingBoundViolations(pendingFixed).isEmpty {
    FileHandle.standardError.write(Data("presence renderer-pending bound gate: positive control rejected\n".utf8))
    exit(1)
}

print("presence renderer-pending bound gate: PASS (a receipt that never came is abandoned on the next request, not refused for ever)")
