import Foundation
import AppKit

// Reuse the existing production coordinator compiler harness, replacing only
// its test program. No coordinator methods or archive implementation are mocked.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let harness = try String(contentsOf: root.appendingPathComponent("tools/test-wish-machine-archive-degradation.swift"), encoding: .utf8)
let start = harness.range(of: "let program = #\"\"\"")!
let end = harness.range(of: "\"\"\"#", range: start.upperBound..<harness.endIndex)!
let program = #"""
import Foundation
import AppKit
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
        let daemon = WishMachineDaemonFixture(directory: dir.appendingPathComponent("generation"), session: URLSession(configuration: .ephemeral))
        let store = fixtureWishStore(directory: dir.appendingPathComponent("generation"), session: .shared, daemonClient: daemon)
        func owner(_ directory: URL) async throws -> WishMachineCoordinator {
            try await fixtureWishCoordinator(store: store, directory: directory, canClaim: { _ in nil })
        }
        func publishAndConsume() throws {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
            let png = bitmap.representation(using: .png, properties: [:])!
            _ = try daemon.serviceRequest(method: "submit", params: ["id": event.wishID.uuidString,
                "endpoint": "https://fixture.invalid", "name": "private notification fixture", "pngBase64": png.base64EncodedString(),
                "heightMeters": 0.5, "source": ["author": "fixture", "license": "CC0"],
                "context": ["worldID": "world", "residentScope": "resident"]])
            _ = try daemon.serviceRequest(method: "publish_message", params: ["id": id.uuidString,
                "taskId": event.wishID.uuidString, "worldID": "world", "residentScope": "resident",
                "kind": "wish.outputReady", "payload": ["wish_id": event.wishID.uuidString, "object_id": "object"]])
            _ = try daemon.serviceRequest(method: "ack_message", params: ["id": id.uuidString,
                "consumer": "agent", "worldID": "world", "residentScope": "resident"])
        }
        let archive = dir.appendingPathComponent("archive")
        try seed(archive)
        let coordinator = try await owner(archive)
        try publishAndConsume()
        do { try await coordinator.acknowledgeEvent(id: id, worldID: "wrong", residentScope: "resident"); fatalError("wrong scope accepted") } catch {}
        assert(!coordinator.isEventAcknowledged(id: id, worldID: "world", residentScope: "resident"))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
        let input = dir.appendingPathComponent("observer-input.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: input)
        let attachment = ResidentImageAttachment(id: UUID(), url: input, displayName: "observer-input.png")
        let observerGrants = [UUID(), UUID()]
        var observerTasks: [Task<Void, Error>] = []
        var observerScheduled = false
        await daemon.controlGate.hold("wish_control_commit")
        coordinator.onChange = {
            guard !observerScheduled else { return }
            observerScheduled = true
            observerTasks = observerGrants.map { grant in Task { @MainActor in
                try await coordinator.authorize(attachments: [attachment], worldID: "world", residentScope: "resident",
                    authorizationID: grant, source: .init(author: "fixture", license: "CC0"))
            } }
        }
        try await coordinator.acknowledgeEvent(id: id, worldID: "world", residentScope: "resident")
        for _ in 0..<250 {
            if await daemon.controlGate.blockedCount > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
        let observerBlocked = await daemon.controlGate.blockedCount
        assert(observerBlocked == 1, "ACK callbacks must not inherit a mutation lease and bypass serialization")
        await daemon.controlGate.release()
        for task in observerTasks { try await task.value }
        coordinator.onChange = nil
        let callbackArchive = try JSONSerialization.jsonObject(with: fixtureWishArchive(directory: archive)) as! [String: Any]
        assert(Set((callbackArchive["authorizations"] as! [[String: Any]]).compactMap { $0["id"] as? String })
            == Set(observerGrants.map(\.uuidString)), "ACK callback grants must both survive real Rust CAS")
        try await coordinator.acknowledgeEvent(id: id, worldID: "world", residentScope: "resident")
        let restarted = try await owner(archive)
        assert(restarted.isEventAcknowledged(id: id, worldID: "world", residentScope: "resident"))
        assert(!restarted.isEventAcknowledged(id: id, worldID: "world", residentScope: "wrong"))
        let failingDir = dir.appendingPathComponent("failure")
        try seed(failingDir)
        let failing = try await owner(failingDir)
        // An explicit rejected Rust control write must not authorize consumption in memory.
        daemon.rejectedControlMethods = ["wish_control_event_ack"]
        do { try await failing.acknowledgeEvent(id: id, worldID: "world", residentScope: "resident"); fatalError("failed persist accepted") } catch {}
        assert(!failing.isEventAcknowledged(id: id, worldID: "world", residentScope: "resident"))
        daemon.rejectedControlMethods = []
        let publishedDir = dir.appendingPathComponent("publish")
        try seed(publishedDir)
        let publishing = try await owner(publishedDir)
        daemon.rejectedControlMethods = ["wish_control_commit"]
        do { try await publishing.markEventPublished(id: id); fatalError("failed publish mark accepted") } catch {}
        daemon.rejectedControlMethods = []
        let recoveredPublish = try await owner(publishedDir)
        assert(recoveredPublish.unpublishedEvents(worldID: "world", residentScope: "resident").map(\.id) == [id])
        try await recoveredPublish.markEventPublished(id: id)
        let finalOwner = try await owner(publishedDir)
        assert(finalOwner.unpublishedEvents(worldID: "world", residentScope: "resident").isEmpty)
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
