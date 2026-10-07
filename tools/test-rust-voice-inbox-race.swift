import Foundation

let source = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/Agent/RustVoiceClient.swift", encoding: .utf8)
var inbox = String(source[source.range(of: "private final class TaskdVoiceHTTPInbox:")!.lowerBound...])
    .replacingOccurrences(of: "private final class", with: "final class")
    .replacingOccurrences(of: "lock.wait()", with: "lock.wait(); lock.unlock(); Race.shared.awakened.signal(); Race.shared.resume.wait(); lock.lock()")
if CommandLine.arguments.contains("--negative-control") {
 let recheck = "        if let waiter { self.waiter = nil; lock.unlock(); waiter.resume(returning: data); return }"
 guard let range = inbox.range(of: recheck, options: .backwards) else { fatalError("missing waiter fix") }
 inbox.removeSubrange(range)
}
let program = #"""
import Foundation
enum RustVoiceError: Error { case invalidFrame, unavailable, rejected(String) }
enum TaskdHTTPError: Error { case invalidFrame, rejected(code: String), unavailable }
final class Race: @unchecked Sendable {
 static let shared = Race()
 let awakened = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
 func waitAwake() -> Bool { awakened.wait(timeout: .now() + 1) == .success }
}
"""# + "\n" + inbox + #"""

@main struct Checks {
 static func main() async throws {
  let inbox = TaskdVoiceHTTPInbox()
  let full = Data(repeating: 1, count: 256 * 1024), next = Data([2])
  inbox.body(full)
  let producer = Task.detached { inbox.body(next) }
  // Wait until the producer has entered its pressure wait. Its source-only
  // instrumentation then releases the lock immediately after condition wake,
  // reproducing the permitted consumer-wins-lock ordering deterministically.
  try await Task.sleep(for: .milliseconds(50))
  guard try await inbox.next() == full else { fatalError("first block changed") }
  let woke = await Task.detached { Race.shared.waitAwake() }.value
  guard woke else { fatalError("producer did not wait") }
  let consumer = Task { try await inbox.next() }
  try await Task.sleep(for: .milliseconds(50))
  Race.shared.resume.signal()
  let received = try await withThrowingTaskGroup(of: Data.self) { group in
   group.addTask { try await consumer.value }
   group.addTask { try await Task.sleep(for: .seconds(1)); inbox.finish(CancellationError()); throw CancellationError() }
   defer { group.cancelAll() }
   return try await group.next()!
  }
  await producer.value
  guard received == next else { fatalError("waiter lost PCM") }
  inbox.finish(CancellationError())
  print("PASS: deterministic pressure wake / newly installed consumer continuation")
 }
}
"""#
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-voice-inbox-race-" + UUID().uuidString)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
let driver = scratch.appendingPathComponent("checks.swift"), binary = scratch.appendingPathComponent("checks")
try program.write(to: driver, atomically: true, encoding: .utf8)
let build = Process(); build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
build.arguments = ["swiftc", "-j1", "-swift-version", "6", "-parse-as-library", driver.path, "-o", binary.path]
try build.run(); build.waitUntilExit(); guard build.terminationStatus == 0 else { exit(build.terminationStatus) }
let run = Process(); run.executableURL = binary
try run.run(); run.waitUntilExit(); exit(run.terminationStatus)
