import Foundation

// Reuse the existing production coordinator compiler harness, replacing only
// its test program. No coordinator methods or archive implementation are mocked.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let harness = try String(contentsOf: root.appendingPathComponent("tools/test-wish-machine-archive-degradation.swift"), encoding: .utf8)
let start = harness.range(of: "let program = #\"\"\"")!
let end = harness.range(of: "\"\"\"#", range: start.upperBound..<harness.endIndex)!
let program = #"""
import Foundation
struct ResidentImageAttachment: Identifiable, Codable, Sendable, Equatable { let id: UUID; let url: URL; let displayName: String }
struct RealtimeDJToolResult { let callID: String; let resultJSON: Data; let isError: Bool }
@MainActor final class ResidentWorldToolSession {
    struct AdditionalTool {
        let name: String; let description: String; let inputSchema: [String: Any]
        let validate: @MainActor ([String: Any]) -> Bool
        let handle: @MainActor (String, Data) async -> RealtimeDJToolResult
    }
}
@main struct Checks {
    @MainActor static func main() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wish-consumption-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let event = WishMachineEvent(id: id, wishID: UUID(), worldID: "world", residentScope: "resident", objectID: "object", kind: .outputReady, computeMayContinue: false)
        func seed(_ directory: URL) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let eventJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event))
            try JSONSerialization.data(withJSONObject: ["authorizations": [], "jobs": [], "events": [eventJSON]])
                .write(to: directory.appendingPathComponent("wishes.json"))
        }
        func owner(_ directory: URL) -> WishMachineCoordinator {
            WishMachineCoordinator(store: fixtureWishStore(directory: dir.appendingPathComponent(UUID().uuidString), session: URLSession(configuration: .ephemeral)), directory: directory, canClaim: { _ in nil })
        }
        let archive = dir.appendingPathComponent("archive")
        try seed(archive)
        let coordinator = owner(archive)
        do { try coordinator.acknowledgeEvent(id: id, worldID: "wrong", residentScope: "resident"); fatalError("wrong scope accepted") } catch {}
        assert(!coordinator.isEventAcknowledged(id: id, worldID: "world", residentScope: "resident"))
        try coordinator.acknowledgeEvent(id: id, worldID: "world", residentScope: "resident")
        try coordinator.acknowledgeEvent(id: id, worldID: "world", residentScope: "resident")
        let restarted = owner(archive)
        assert(restarted.isEventAcknowledged(id: id, worldID: "world", residentScope: "resident"))
        assert(!restarted.isEventAcknowledged(id: id, worldID: "world", residentScope: "wrong"))
        let failingDir = dir.appendingPathComponent("failure")
        try seed(failingDir)
        let failing = owner(failingDir)
        // A directory at the rename target deterministically prevents commit.
        try FileManager.default.removeItem(at: failingDir.appendingPathComponent("wishes.json"))
        try FileManager.default.createDirectory(at: failingDir.appendingPathComponent("wishes.json"), withIntermediateDirectories: false)
        do { try failing.acknowledgeEvent(id: id, worldID: "world", residentScope: "resident"); fatalError("failed persist accepted") } catch {}
        assert(!failing.isEventAcknowledged(id: id, worldID: "world", residentScope: "resident"))
        let publishedDir = dir.appendingPathComponent("publish")
        try seed(publishedDir)
        let publishing = owner(publishedDir)
        let publishArchive = publishedDir.appendingPathComponent("wishes.json")
        let durableBeforePublish = try Data(contentsOf: publishArchive)
        try FileManager.default.removeItem(at: publishArchive)
        try FileManager.default.createDirectory(at: publishArchive, withIntermediateDirectories: false)
        do { try publishing.markEventPublished(id: id); fatalError("failed publish mark accepted") } catch {}
        try FileManager.default.removeItem(at: publishArchive)
        try durableBeforePublish.write(to: publishArchive)
        let recoveredPublish = owner(publishedDir)
        assert(recoveredPublish.unpublishedEvents(worldID: "world", residentScope: "resident").map(\.id) == [id])
        try recoveredPublish.markEventPublished(id: id)
        assert(owner(publishedDir).unpublishedEvents(worldID: "world", residentScope: "resident").isEmpty)
        print("PASS: production coordinator consumption restart, duplicate, scope, persistence failure and publish checks")
    }
}
"""#
let runner = String(harness[..<start.lowerBound]) + "let program = #\"\"\"\n" + program + "\n\"\"\"#" + String(harness[end.upperBound...])
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("wish-consumption-runner-" + UUID().uuidString + ".swift")
try runner.write(to: temporary, atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(at: temporary) }
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/swift"); process.arguments = [temporary.path]
try process.run(); process.waitUntilExit(); exit(process.terminationStatus)
