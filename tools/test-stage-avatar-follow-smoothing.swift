// Run from the repository root: swift tools/test-stage-avatar-follow-smoothing.swift
// Hostless red/green driver for the avatar-follow camera smoothing.
//
// RED state (before implementation): the production declarations
// `AvatarFollowYawDigester` / `AvatarFollowUserPolicy` are missing from
// StageCameraCoordinator.swift, so the harness cannot compile and the driver
// exits non-zero.
// GREEN state (after implementation): the real production types are extracted
// and exercised, and the driver prints PASS.
//
// No app, GPU, network or user settings are opened.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = try String(
    contentsOf: root.appendingPathComponent(
        "apps/macos/Sources/GMGNRadio/VisualEngine/StageCameraCoordinator.swift"
    ),
    encoding: .utf8
)

func declaration(_ signature: String, in source: String) -> String? {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{")
    else {
        return nil
    }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    return nil
}

guard let digester = declaration("struct AvatarFollowYawDigester:", in: source) else {
    print("FAIL: production declaration struct AvatarFollowYawDigester: not found")
    exit(1)
}
guard let policy = declaration("enum AvatarFollowUserPolicy {", in: source) else {
    print("FAIL: production declaration enum AvatarFollowUserPolicy { not found")
    exit(1)
}

let harness = #"""
import Foundation
import Darwin

\#(digester)
\#(policy)

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}
func near(_ a: Float, _ b: Float, tolerance: Float = 0.0005) -> Bool {
    abs(a - b) <= tolerance
}

// --- single queued step is NOT applied in a whole 30 Hz jump ----------------
var digester = AvatarFollowYawDigester()
check(digester.isEmpty, "digester starts empty")
digester.enqueue(0.4)
check(!digester.isEmpty, "enqueue stores pending rotation")
let firstFrame = digester.advance(deltaTime: 1.0 / 60.0)
check(firstFrame > 0, "a render frame consumes some follow rotation")
check(firstFrame < 0.4 * 0.6, "first frame applies far less than the whole step")
check(abs(digester.pending - (0.4 - firstFrame)) < 0.000001,
      "consumed rotation exactly reduces the pending amount")

// --- conservation: every queued radian is eventually applied (no snap-back) --
var conserved = AvatarFollowYawDigester()
conserved.enqueue(0.22)
conserved.enqueue(0.31)
conserved.enqueue(-0.07)
let total = conserved.pending
var appliedTotal: Float = 0
for _ in 0..<600 {
    let applied = conserved.advance(deltaTime: 1.0 / 120.0)
    appliedTotal += applied
    if abs(applied) > abs(conserved.pending) + 0.000001 {
        check(false, "advance never over-applies")
        break
    }
}
check(near(conserved.pending, 0, tolerance: 0.00001), "follow backlog fully drains")
check(near(appliedTotal, total, tolerance: 0.0005),
      "sum of per-frame rotation conserves the queued total")

// --- longer render intervals consume a larger fraction of the same backlog ---
var fast = AvatarFollowYawDigester()
fast.enqueue(1)
let fastApplied = fast.advance(deltaTime: 1.0 / 60.0)
var slow = AvatarFollowYawDigester()
slow.enqueue(1)
let slowApplied = slow.advance(deltaTime: 1.0 / 24.0)
check(slowApplied > fastApplied, "slower frame rate digests more per frame")
check(slowApplied < 1, "even a 24 fps frame does not apply the whole backlog")
check(fastApplied > 0.2, "60 fps still digests a meaningful fraction")

// --- a stale backlog after a long render gap is dropped, never swung ---------
var stale = AvatarFollowYawDigester()
stale.enqueue(5.0)
let appliedAfterGap = stale.advance(deltaTime: 2.0)
check(appliedAfterGap == 0, "gap longer than the reset threshold applies nothing")
check(stale.isEmpty, "stale backlog is discarded instead of swung in one frame")

// --- cancellation drops pending without touching applied history -------------
var cancelled = AvatarFollowYawDigester()
cancelled.enqueue(0.5)
cancelled.cancel()
check(cancelled.isEmpty, "cancel drops the queued follow rotation")
check(cancelled.advance(deltaTime: 1.0 / 60.0) == 0,
      "cancelled digester never applies late rotation")

// --- non-finite deltas are ignored -------------------------------------------
var poisoned = AvatarFollowYawDigester()
poisoned.enqueue(.nan)
poisoned.enqueue(.infinity)
poisoned.enqueue(-.infinity)
check(poisoned.isEmpty, "non-finite follow deltas are ignored")

// --- zero / invalid advance is a no-op ---------------------------------------
var idle = AvatarFollowYawDigester()
idle.enqueue(0.3)
check(idle.advance(deltaTime: 0) == 0, "zero delta consumes nothing")
check(idle.advance(deltaTime: -1) == 0, "negative delta consumes nothing")
check(near(idle.pending, 0.3), "invalid advances preserve the backlog")

// --- user interaction policy suppresses follow while the user is active ------
check(!AvatarFollowUserPolicy.acceptsFollowYaw(secondsSinceUserInteraction: 0),
      "follow is suppressed right after a user camera drag")
check(!AvatarFollowUserPolicy.acceptsFollowYaw(secondsSinceUserInteraction: 0.2),
      "follow stays suppressed during an active drag")
check(AvatarFollowUserPolicy.acceptsFollowYaw(
    secondsSinceUserInteraction: AvatarFollowUserPolicy.suppressionInterval
), "follow resumes once the user has been idle for the suppression interval")
check(AvatarFollowUserPolicy.acceptsFollowYaw(secondsSinceUserInteraction: 5),
      "follow resumes long after the last user camera interaction")
check(AvatarFollowUserPolicy.suppressionInterval > 0
        && AvatarFollowUserPolicy.suppressionInterval <= 3,
      "suppression interval is a sane short cooldown")

if failures > 0 {
    print("\(failures) assertions failed")
    exit(1)
}
print("PASS: avatar follow yaw is queued at snapshot cadence and digested smoothly across render frames")
"""#

let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "gmgn-avatar-follow-smoothing-\(UUID())"
)
try FileManager.default.createDirectory(
    at: temporaryDirectory,
    withIntermediateDirectories: false
)
defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
let harnessURL = temporaryDirectory.appendingPathComponent("main.swift")
try harness.write(to: harnessURL, atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = [harnessURL.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
