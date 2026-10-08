import Foundation

// Compile the production Coordinator and reuse only the existing test type declarations.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let harness = try String(contentsOf: root.appendingPathComponent("tools/test-wish-machine-archive-degradation.swift"), encoding: .utf8)
let start = harness.range(of: "let program = #\"\"\"")!
let end = harness.range(of: "\"\"\"#", range: start.upperBound..<harness.endIndex)!
let types = try String(contentsOf: root.appendingPathComponent("tools/test-wish-notification-consumption.swift"), encoding: .utf8)
let typeStart = types.range(of: "let program = #\"\"\"")!.upperBound
let typeEnd = types.range(of: "@main struct Checks", range: typeStart..<types.endIndex)!.lowerBound
let program = String(types[typeStart..<typeEnd]) + #"""
@main struct Checks {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wish-control-concurrency-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let daemon = WishMachineDaemonFixture(directory: directory.appendingPathComponent("generation"), session: .shared)
        let store = fixtureWishStore(directory: directory.appendingPathComponent("generation"), session: .shared, daemonClient: daemon)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
        let image = directory.appendingPathComponent("input.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: image)
        let attachment = ResidentImageAttachment(id: UUID(), url: image, displayName: "input.png")
        func waitBlocked(_ count: Int = 1) async throws {
            for _ in 0..<250 {
                if await daemon.controlGate.blockedCount == count { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            fatalError("control gate did not block the expected RPC")
        }
        let wishes = directory.appendingPathComponent("wishes")
        await daemon.controlGate.hold("wish_control_open")
        let coordinator = WishMachineCoordinator(store: store, directory: wishes,
            wishControlCall: { method, bytes in try await daemon.asyncControlRequest(method: method, data: bytes) },
            canClaim: { _ in nil })
        let grantA = UUID(), grantB = UUID()
        let first = Task { @MainActor in
            try await coordinator.authorize(attachments: [attachment], worldID: "world", residentScope: "resident",
                authorizationID: grantA, source: .init(author: "fixture", license: "CC0"))
        }
        try await waitBlocked()
        assert(!coordinator.isReadable && (try? fixtureWishArchive(directory: wishes)) == nil
            && coordinator.jobs.isEmpty && daemon.jobs.isEmpty)
        await daemon.controlGate.release()
        try await first.value
        assert(coordinator.isReadable)
        await daemon.controlGate.hold("wish_control_commit")
        let second = Task { @MainActor in
            try await coordinator.authorize(attachments: [attachment], worldID: "world", residentScope: "resident",
                authorizationID: grantB, source: .init(author: "fixture", license: "CC0"))
        }
        let grantC = UUID()
        let third = Task { @MainActor in
            try await coordinator.authorize(attachments: [attachment], worldID: "world", residentScope: "resident",
                authorizationID: grantC, source: .init(author: "fixture", license: "CC0"))
        }
        try await waitBlocked()
        try await Task.sleep(for: .milliseconds(100))
        let blocked = await daemon.controlGate.blockedCount
        assert(blocked == 1, "concurrent writes must serialize before Rust CAS")
        await daemon.controlGate.release()
        try await second.value; try await third.value
        let archive = try JSONSerialization.jsonObject(with: fixtureWishArchive(directory: wishes)) as! [String: Any]
        let grants = archive["authorizations"] as! [[String: Any]]
        assert(Set(grants.compactMap { $0["id"] as? String }) == Set([grantA, grantB, grantC].map(\.uuidString)))
        await daemon.controlGate.hold("wish_control_commit")
        let rejected = Task { @MainActor in
            try await coordinator.submit(requestID: "rejected-before-generation", authorizationID: grantA,
                attachmentID: attachment.id, name: "private fixture", heightMeters: 0.5,
                worldID: "world", residentScope: "resident")
        }
        try await waitBlocked()
        assert(coordinator.jobs.isEmpty && daemon.jobs.isEmpty && store.jobs.isEmpty,
            "an uncommitted wish must not become a visible job or start provider work")
        daemon.rejectedControlMethods = ["wish_control_commit"]
        await daemon.controlGate.release()
        do { _ = try await rejected.value; fatalError("rejected commit accepted") } catch {}
        assert(coordinator.jobs.isEmpty && daemon.jobs.isEmpty && store.jobs.isEmpty)
        let after = try JSONSerialization.jsonObject(with: fixtureWishArchive(directory: wishes)) as! [String: Any]
        assert((after["jobs"] as! [Any]).isEmpty)
        print("PASS: real Rust authority initialization wait, serialized grants, no premature projection and rejected-write zero generation effects")
    }
}
"""#
let runner = String(harness[..<start.lowerBound]) + "let program = #\"\"\"\n" + program + "\n\"\"\"#" + String(harness[end.upperBound...])
let file = FileManager.default.temporaryDirectory.appendingPathComponent("wish-control-concurrency-runner-" + UUID().uuidString + ".swift")
try runner.write(to: file, atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(at: file) }
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/swift"); process.arguments = [file.path]
try process.run(); process.waitUntilExit(); exit(process.terminationStatus)
