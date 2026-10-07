import Foundation
import WorldRuntime
@testable import UnityMediaHost

// Real provider acceptance. Link against the freshly built native host module.
// Argument 1 is a taskd executable; all durable state lives in a new temp root.
// No credentials, formal settings, app bundles, or human read flags are changed.
@main struct UnityInboxLiveAcceptance {
    enum AcceptanceError: Error { case daemonUnavailable, verification(String) }
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw AcceptanceError.verification(message) }
    }
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            print("Usage: test-unity-inbox-live /absolute/path/gmgn-taskd")
            exit(2)
        }
        let fm = FileManager.default
        // Foundation preserves macOS's /var alias; taskd rejects symlink ancestors.
        guard let canonicalTemporaryPath = realpath(fm.temporaryDirectory.path, nil) else {
            throw AcceptanceError.daemonUnavailable
        }
        let temporaryPath = String(cString: canonicalTemporaryPath)
        free(canonicalTemporaryPath)
        let root = URL(fileURLWithPath: temporaryPath)
            .appendingPathComponent("gmgn-unity-inbox-live-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let taskRoot = root.appendingPathComponent("gmgn radio/TaskService")
        try fm.createDirectory(at: taskRoot, withIntermediateDirectories: true)
        let endpoint = taskRoot.appendingPathComponent("taskd.endpoint.json")
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        daemon.arguments = ["--root", taskRoot.path, "--endpoint-file", endpoint.path, "--concurrency", "1"]
        daemon.standardOutput = FileHandle.nullDevice
        daemon.standardError = FileHandle.standardError
        try daemon.run()
        defer {
            if daemon.isRunning { daemon.terminate(); daemon.waitUntilExit() }
            // Keep isolated state as a reviewable receipt, including failures.
            print("isolated_receipt_root: \(root.path)")
        }
        let deadline = Date().addingTimeInterval(15)
        while !fm.fileExists(atPath: endpoint.path), daemon.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard daemon.isRunning, fm.fileExists(atPath: endpoint.path) else {
            throw AcceptanceError.daemonUnavailable
        }

        let worldID = "acceptance.inbox." + UUID().uuidString
        let residentScope = "resident.world." + Data(worldID.utf8).base64EncodedString()
        let scope = ResidentStateScope(worldID: worldID, residentScope: residentScope)
        let client = ResidentStateClient(transport: ResidentTaskDaemonStateTransport(client:
            PropTaskDaemonClient(root: taskRoot, allowsLaunching: false)))
        let inbox = UnityInboxBridge(root: root, worldID: worldID, residentScope: residentScope)
        defer { inbox.close() }
        let id = UUID(), nonce = "INBOX_LIVE_" + UUID().uuidString
        let posted = try await inbox.postForAgent(id: id, title: "真实收件箱反馈验收",
            detail: "用户授权本条通知只做反馈验收。请回复唯一标识 \(nonce)。必须先调用 read_system_inbox 读取实际内容。不得生成、领取、摆放、删除、播放或执行任何其他动作。")
        try require(posted, "message post rejected")
        let before = try await inbox.readForAgent()
        try require(before.count == 1 && before[0].lastEventID == id.uuidString && !before[0].isRead, "posted inbox readback failed")

        let identity: [Float] = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
        let manifest = WorldManifest(schemaVersion: 1, packageID: worldID, packageVersion: "1", worldID: worldID,
            displayName: "Inbox acceptance", calibration: .init(visualToGameplay: identity, metersPerUnit: 1),
            spawn: .init(position: .init(x: 0, y: 0, z: 0), rotation: .init(x: 0, y: 0, z: 0, w: 1), scale: .init(x: 1, y: 1, z: 1)),
            collisionVolumes: [], waypoints: [], routes: [], activities: [], cameras: [], capabilities: [], resources: [])
        let context = try WorldAgentContext(manifest: manifest,
            persistence: AtomicJSONWorldStatePersistence(fileURL: root.appendingPathComponent("world.json")))
        let dispatcher = WorldAgentToolDispatcher(takeoverEnabled: { false }, context: context)
        let defaultsName = "ai.gmgn.inbox-live." + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let conversation = try RenderHostResidentConversation(backend: "dsh", dataRoot: root, defaults: defaults)
        defer { conversation.close() }
        var events: [ResidentAgentLoop.Event] = []
        let consumer = UnityResidentInboxAgent(client: client, scope: scope) { events.append($0); return true }
        defer { consumer.close() }
        var reads = 0
        conversation.setWorldServices(.init(context: context, dispatcher: dispatcher, isCurrent: { true },
            additionalTools: { _, _, _ in [] }, onCancel: {}, backgroundTools: { runID, isCurrent in
                UnityInboxAgentTools.tools(inbox: inbox, isCurrent: isCurrent, didRead: { entries in
                    reads += 1
                    consumer.noteRead(entries: entries, runID: runID)
                })
            }))
        try await consumer.refresh()
        try require(events.count == 1 && !events[0].summary.contains(nonce), "nonce must only reach model through inbox tool")
        let runID = UUID()
        let input = ResidentAgentLoop.Input(runID: runID, userMessages: [], imageURLs: [], events: events,
            intent: nil, intentPausedByUser: true, isBackground: true, lastTurnUserMessages: [],
            lastTurnInterrupted: false, unconfirmedUserMessages: [], recentObservations: [], previousTurnFailed: false)
        let reply: String
        do { reply = try await conversation.runBackground(input: input) }
        catch { consumer.failed(events: events, runID: runID); throw error }
        try require(reads > 0, "provider must invoke actual inbox tool")
        try require(reply.contains(nonce), "real provider reply must contain inbox-only nonce")
        try await consumer.complete(events: events, runID: runID)
        let remaining = try await client.messageRead(scope: scope, consumer: UnityResidentInboxAgent.consumer, after: 0, limit: 100)
        try require(remaining.messages.isEmpty, "consumed message must be durably acknowledged")
        let after = try await inbox.readForAgent()
        try require(after.count == 1 && !after[0].isRead, "agent consumption must preserve human unread flag")
        print("PASS: real taskd post/read; native DSH provider invoked read_system_inbox; nonce reply; durable consumer ACK; human unread preserved")
        print("message_id: \(id.uuidString)")
        print("read_system_inbox_calls: \(reads)")
        print("reply: \(reply)")
    }
}
