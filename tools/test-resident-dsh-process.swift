import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-dsh-process-test-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let harness = #"""
import Foundation
import Darwin

@main struct Tests {
    @MainActor static func main() async throws {
        var failures = 0
        func check(_ condition: Bool, _ description: String) {
            if !condition { failures += 1; print("FAIL: \(description)") }
        }
        let runner = DSHProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/python3"))
        let warned = try await runner.run(arguments: ["-c", "import sys; print('dsh: failed to load .env', file=sys.stderr); print('{\"type\":\"final\",\"text\":\"你好\"}')"], standardInput: nil)
        check(warned.exitCode == 0 && warned.output == "{\"type\":\"final\",\"text\":\"你好\"}", "successful headless JSON excludes stderr warnings")
        let failure = try await runner.run(arguments: ["-c", "import sys; print('partial model reply'); print('dsh: invalid_api_key', file=sys.stderr); sys.exit(1)"], standardInput: nil)
        check(failure.exitCode == 1 && failure.output == "dsh: invalid_api_key", "failed headless request retains stderr diagnostics without partial stdout")
        let noisy = DSHProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), requestTimeout: 3)
        let flooded = try await noisy.run(arguments: ["-c", "import sys; sys.stderr.write('warning' * 100000); sys.stderr.flush(); print('clean reply')"], standardInput: nil)
        check(flooded.output == "clean reply", "stderr larger than the pipe buffer drains concurrently without polluting stdout")
        let duplex = try await noisy.run(arguments: ["-c", "import sys; sys.stdout.write('中' * 100000); sys.stdout.flush(); sys.stderr.write('diagnostic' * 100000); sys.stderr.flush(); data=sys.stdin.read(); print(len(data))"], standardInput: String(repeating: "x", count: 300000))
        check(duplex.output == String(repeating: "中", count: 100000) + "300000", "large stdin, stdout and stderr can progress together without losing UTF-8 output")
        let started = Date()
        let pending = Task {
            try await runner.run(arguments: ["-c", "import time; time.sleep(1.5); print('late')"], standardInput: nil)
        }
        try await Task.sleep(for: .milliseconds(250))
        pending.cancel()
        var cancelled = false
        do { _ = try await pending.value } catch is CancellationError { cancelled = true }
        check(cancelled, "cancellation is returned by the real child-process runner")
        check(Date().timeIntervalSince(started) < 1, "cancelled child does not hold its caller until natural exit")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-owned-child-\(UUID())")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let pidFile = work.appendingPathComponent("pid")
        let stubborn = Task {
            try await runner.run(arguments: ["-c", "import os,sys,signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); open(sys.argv[1],'w').write(str(os.getpid())); time.sleep(3); print('late')", pidFile.path], standardInput: nil)
        }
        let readyDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < readyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        stubborn.cancel()
        do { _ = try await stubborn.value; check(false, "stubborn child cancellation fails the request") }
        catch is CancellationError {}
        let next = try await runner.run(arguments: ["-c", "import time; time.sleep(0.6); print('next reply')"], standardInput: nil)
        check(next.output == "next reply", "old cancellation grace cannot terminate a new invocation")
        check(kill(pid, 0) == -1 && errno == ESRCH, "the owned child that ignored TERM was reaped")

        let timed = DSHProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), requestTimeout: 0.15)
        let timeoutStart = Date()
        var timedOut = false
        do { _ = try await timed.run(arguments: ["-c", "import time; time.sleep(2)"], standardInput: nil) }
        catch DSHReplyTimeout.request { timedOut = true }
        check(timedOut && Date().timeIntervalSince(timeoutStart) < 1, "a real child has a bounded request timeout")
        let timeoutPIDFile = work.appendingPathComponent("timeout-pid")
        let trapping = DSHProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), requestTimeout: 0.5)
        var trappedTimeout = false
        do {
            _ = try await trapping.run(arguments: ["-c", "import os,sys,signal,time; signal.signal(signal.SIGTERM, lambda *_: sys.exit(0)); open(sys.argv[1],'w').write(str(os.getpid())); time.sleep(3)", timeoutPIDFile.path], standardInput: nil)
        } catch DSHReplyTimeout.request { trappedTimeout = true }
        check(trappedTimeout, "a timeout stays a timeout when the child handles TERM by exiting zero")
        let timeoutPID = Int32(try String(contentsOf: timeoutPIDFile, encoding: .utf8))!
        let reapDeadline = Date().addingTimeInterval(1)
        while kill(timeoutPID, 0) == 0, Date() < reapDeadline { try await Task.sleep(for: .milliseconds(10)) }
        check(kill(timeoutPID, 0) == -1 && errno == ESRCH, "timed-out child is reaped after its graceful exit")
        let normal = try await runner.run(arguments: ["-c", "import sys; print('中文回复'); sys.exit(7)"], standardInput: nil)
        check(normal.exitCode == 7 && normal.output == "中文回复", "normal exit preserves diagnostic classification input")
        let preCancelledFile = work.appendingPathComponent("must-not-launch")
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(arguments: ["-c", "import sys; open(sys.argv[1],'w').write('launched')", preCancelledFile.path], standardInput: nil)
        }
        do { _ = try await preCancelled.value; check(false, "pre-cancelled invocation fails") }
        catch is CancellationError {}
        check(!FileManager.default.fileExists(atPath: preCancelledFile.path), "pre-cancelled invocation never launches a child")
        print("\(failures == 0 ? "PASS" : "FAIL"): DSH owned-process cancellation, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let main = work.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("test")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-swift-version", "6", "-parse-as-library", "-j1", root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/CodexCLI.swift").path, main.path, "-o", binary.path]
try compile.run(); compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process(); test.executableURL = binary
try test.run(); test.waitUntilExit(); exit(test.terminationStatus)
