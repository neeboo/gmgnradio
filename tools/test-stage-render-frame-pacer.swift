// Run from the repository root: swift tools/test-stage-render-frame-pacer.swift
// Hostless red/green driver for the explicit render loop's frame cadence.
//
// RED state (before implementation): the production declaration
// `struct StageRenderFramePacer` is missing from StageRenderSurfaceController.swift,
// so the harness cannot compile and the driver exits non-zero.
// GREEN state (after implementation): the real production type is extracted
// and exercised, and the driver prints PASS.
//
// No app, GPU, network or user settings are opened.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = try String(
    contentsOf: root.appendingPathComponent(
        "apps/macos/Sources/GMGNRadio/VisualEngine/StageRenderSurfaceController.swift"
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

guard let pacer = declaration("struct StageRenderFramePacer:", in: source) else {
    print("FAIL: production declaration struct StageRenderFramePacer: not found")
    exit(1)
}

let harness = #"""
import Foundation
import Darwin

\#(pacer)

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}
func near(_ a: Double, _ b: Double, tolerance: Double = 0.000000001) -> Bool {
    abs(a - b) <= tolerance
}

/// Simulates the explicit render loop against the real pacer type:
/// sleep the pacer's idle, draw for `duration`, then record the frame.
func run(
    interval: TimeInterval,
    drawDurations: [TimeInterval]
) -> (starts: [TimeInterval], idles: [TimeInterval]) {
    var pacer = StageRenderFramePacer(interval: interval, firstFrameAt: 0)
    var now: TimeInterval = 0
    var starts: [TimeInterval] = []
    var idles: [TimeInterval] = []
    for duration in drawDurations {
        let idle = pacer.idleTime(now: now)
        idles.append(idle)
        now += idle
        let start = now
        starts.append(start)
        now += duration
        let end = now
        pacer.frameDrew(startedAt: start, endedAt: end)
    }
    return (starts, idles)
}

let interval = 1.0 / 24.0
let drawCPU = 0.004

// --- steady state subtracts this frame's draw time from the idle ------------
// Frame n must start exactly n*interval: cadence is interval, not drawCPU +
// interval. With drawCPU = 4 ms at 24 fps the naive loop would otherwise run
// at ~21.9 fps (drawCPU + full interval).
let steady = run(
    interval: interval,
    drawDurations: Array(repeating: drawCPU, count: 24)
)
for frame in 0..<24 {
    check(
        near(steady.starts[frame], Double(frame) * interval),
        "steady frame \(frame) starts on the target cadence"
    )
}
check(near(steady.idles[1], interval - drawCPU),
      "idle subtracts the previous frame's draw time from the target interval")

// --- an overrunning frame never triggers burst catch-up frames ----------------
// drawCPU > interval: the next frame starts immediately (machine-bound), the
// cadence equals the real draw cost, and no queue of missed beats accumulates.
let machineBound = run(
    interval: 0.05,
    drawDurations: Array(repeating: 0.07, count: 10)
)
for frame in 1..<10 {
    check(
        near(machineBound.starts[frame] - machineBound.starts[frame - 1], 0.07),
        "overrunning frames are machine-bound at the draw cost, frame \(frame)"
    )
}

// --- a single long main-actor hiccup drops its missed beats, then re-locks ---
// A 200 ms hiccup on the frame that starts at 2*interval overruns its slot.
// The following frame begins immediately once (the missed beats are dropped,
// not burst-rendered) and the cadence re-locks on the next interval.
let hiccupDurations = [0.004, 0.004, 0.2] + Array(repeating: 0.004, count: 8)
let hiccup = run(interval: interval, drawDurations: hiccupDurations)
check(near(hiccup.starts[0], 0), "first frame starts immediately")
check(near(hiccup.starts[1], interval), "frame 1 starts on cadence")
check(near(hiccup.starts[2], 2 * interval), "the hiccup frame still starts on cadence")
check(near(hiccup.starts[3], 2 * interval + 0.2),
      "the frame right after the overrunning hiccup starts immediately")
check(near(hiccup.starts[4] - hiccup.starts[3], interval),
      "cadence re-locks exactly one interval after the hiccup frame")
check(hiccup.idles[3] == 0, "the post-hiccup frame has zero idle (beats dropped, not caught up)")
var zeroIdleAfterHiccup = 0
for frame in 4..<hiccup.idles.count where hiccup.idles[frame] == 0 {
    zeroIdleAfterHiccup += 1
}
check(zeroIdleAfterHiccup == 0, "no further zero-idle catch-up frames after the hiccup")
check(near(hiccup.idles[4], interval - drawCPU),
      "after the hiccup, idles resume at interval minus the draw time")

// --- interval clamping protects the loop from a zero/negative fps input ------
var clamped = StageRenderFramePacer(interval: 0, firstFrameAt: 0)
check(clamped.interval > 0, "pacer clamps a non-positive interval to a tiny positive one")
var clampedAgain = StageRenderFramePacer(interval: -2, firstFrameAt: 0)
check(clampedAgain.interval > 0, "pacer clamps a negative interval")

if failures > 0 {
    print("\(failures) assertions failed")
    exit(1)
}
print("PASS: render loop cadence subtracts frame draw time, drops missed beats without busy catch-up")
"""#

let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "gmgn-render-frame-pacer-\(UUID())"
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
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }

// Compile and exercise the actual asynchronous driver as well as its math.
// A pure pacer simulation cannot detect actor starvation or a cancelled
// sleeper drawing one more frame.
guard let startLoop = declaration("private func startRenderLoop()", in: source),
      let stopLoop = declaration("private func stopRenderLoop()", in: source)
else { fatalError("Missing production render loop") }
guard let diagnosticsStart = source.range(of: "    private var schedulingIntervalsMS:")?.lowerBound,
      let diagnosticsEnd = source.range(of: "    init(", range: diagnosticsStart..<source.endIndex)?.lowerBound
else { fatalError("Missing production scheduling diagnostics") }
let diagnostics = String(source[diagnosticsStart..<diagnosticsEnd])
let driverHarness = #"""
import Foundation
import Darwin
\#(pacer)
enum StageRenderLoopMode { case stopped, manual(framesPerSecond: Int) }
@MainActor final class Surface {
    var isHidden = false
    var drawMicroseconds: useconds_t = 0
    var frames = 0
    func draw() {
        frames += 1
        usleep(drawMicroseconds)
    }
}
@MainActor final class Driver {
    let surfaceView = Surface()
    var renderLoopTask: Task<Void, Never>?
    var renderLoopMode = StageRenderLoopMode.manual(framesPerSecond: 100)
    \#(diagnostics)
    \#(startLoop)
    \#(stopLoop)
    func start() { startRenderLoop() }
    func stop() { stopRenderLoop() }
    func seedDiagnostics() {
        for index in 0..<150 {
            recordRenderScheduling(
                intervalMS: 60, overshootMS: Double(index), drawDurationMS: 2,
                startedAtUptime: Double(index), runLoopMode: "test", waited: true
            )
        }
    }
}
@main struct Tests {
    @MainActor static func main() async throws {
        let watchdog = Task.detached {
            try await Task.sleep(for: .seconds(3))
            print("FAIL: overrunning draw loop monopolized the main actor")
            exit(1)
        }
        let busy = Driver()
        busy.surfaceView.drawMicroseconds = 30_000
        busy.start()
        try await Task.sleep(for: .milliseconds(100))
        busy.stop()
        let busyFrames = busy.surfaceView.frames
        try await Task.sleep(for: .milliseconds(30))
        precondition(busyFrames > 0 && busyFrames < 30,
            "slow rendering must allow the main actor to process cancellation")
        precondition(busy.surfaceView.frames == busyFrames,
            "cancellation must prevent another slow frame")
        let sleeping = Driver()
        sleeping.renderLoopMode = .manual(framesPerSecond: 2)
        sleeping.start()
        try await Task.sleep(for: .milliseconds(40))
        precondition(sleeping.surfaceView.frames == 1)
        sleeping.stop()
        try await Task.sleep(for: .milliseconds(40))
        precondition(sleeping.surfaceView.frames == 1,
            "cancelled sleeping loop must not draw one extra frame")
        let recorded = Driver()
        recorded.seedDiagnostics()
        let metrics = recorded.renderSchedulingDiagnostics
        let intervals = metrics["drawStartInterval"] as! [String: Any]
        precondition(intervals["samples"] as! Int == 120)
        let longIntervals = metrics["longDrawStartIntervals"] as! [[String: Any]]
        precondition(longIntervals.count == 12)
        precondition(longIntervals.first?["startedAtSystemUptime"] as! Double == 138)
        precondition(longIntervals.last?["waitResumeOvershootMS"] as! Double == 149)
        sleeping.start()
        try await Task.sleep(for: .milliseconds(40))
        sleeping.stop()
        let restartMetrics = sleeping.renderSchedulingDiagnostics
        precondition((restartMetrics["drawStartInterval"] as! [String: Any])["samples"] as! Int == 0,
            "stopped time must not become a draw interval on restart")
        let quality = Driver()
        quality.start()
        try await Task.sleep(for: .milliseconds(40))
        let beforeQualityChange = quality.surfaceView.frames
        quality.renderLoopMode = .manual(framesPerSecond: 12)
        quality.start()
        try await Task.sleep(for: .milliseconds(120))
        quality.stop()
        precondition(quality.surfaceView.frames - beforeQualityChange <= 3,
            "lower quality cadence must re-anchor without catch-up")
        watchdog.cancel()
        print("PASS: production async render loop yields under load, cancels/restarts and bounds diagnostics")
    }
}
"""#
let driverURL = temporaryDirectory.appendingPathComponent("Driver.swift")
try driverHarness.write(to: driverURL, atomically: true, encoding: .utf8)
let executable = temporaryDirectory.appendingPathComponent("driver")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-swift-version", "6", "-parse-as-library", driverURL.path, "-o", executable.path]
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let driver = Process()
driver.executableURL = executable
try driver.run()
driver.waitUntilExit()
exit(driver.terminationStatus)
