import Foundation

// Real-subprocess tests for ResidentDSHConnector against a local fake ACP
// server (python3). No Codex model, host app or credentials are touched.
// Modes exercised:
//   noread — stops reading stdin after session/new: a large prompt write must
//            block in the IO queue while Task.cancel still returns bounded and
//            the owned subprocess exits.
//   chat   — graceful cancellation survives beyond the grace window on the
//            same session; cross-session and late chunks never pollute replies.

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
// Response routing settles chunk collection before the suspended prompt resumes.
// It must keep the single-prompt lease until that prompt's defer has finished;
// clearing both flags here would admit a new turn that the old defer can erase.
let transportSource = try String(contentsOf: root.appendingPathComponent(
    "apps/macos/Sources/GMGNRadio/Agent/ResidentDSHTransport.swift"), encoding: .utf8)
guard let settlement = transportSource.components(separatedBy: "if waiting.method == \"session/prompt\" {").dropFirst().first?
    .components(separatedBy: "\n        }").first,
      settlement.contains("activeSessionID = nil"), !settlement.contains("promptInFlight = false") else {
    print("FAIL: response routing releases the prompt lease before the awaiting turn finishes")
    exit(1)
}
let build = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-dsh-transport-build-\(UUID())", isDirectory: true)
try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: build) }

let harness = ##"""
import Foundation

// Delay only executor delivery of onCancel in the temporary compiled copy.
// The production transport's cancellation and wire logic remains intact.
@MainActor enum TransportCancellationGate {
    static var armed = false
    static var entered = false
    static var delivered = false
    static var waiter: CheckedContinuation<Void, Never>?
    static func waitIfArmed() async {
        guard armed else { return }
        entered = true
        await withCheckedContinuation { waiter = $0 }
        delivered = true
    }
    static func release() {
        armed = false
        waiter?.resume()
        waiter = nil
    }
}

@MainActor enum TransportPromptSettlementGate {
    static var armed = false
    static var entered = false
    static var waiter: CheckedContinuation<Void, Never>?
    static func waitIfArmed() async {
        guard armed else { return }
        entered = true
        await withCheckedContinuation { waiter = $0 }
    }
    static func release() {
        armed = false
        waiter?.resume()
        waiter = nil
    }
}

@MainActor enum TransportAdmissionCancellation {
    static var armed = false
    static func cancelIfArmed() {
        guard armed else { return }
        armed = false
        withUnsafeCurrentTask { $0?.cancel() }
    }
}

struct FixtureDSHLocator: AgentExecutableLocating {
    func locate(executableNames: [String]) -> URL? { URL(fileURLWithPath: "/fixture/dsh") }
}

@MainActor final class ReopeningFixtureConnector: ResidentDSHImageConnecting {
    let work: URL
    let make: (Int) -> ResidentDSHConnector
    private(set) var opens = 0
    private var real: ResidentDSHConnector?
    init(work: URL, make: @escaping (Int) -> ResidentDSHConnector) { self.work = work; self.make = make }
    var isUsable: Bool { real?.isUsable ?? true }
    func openSession(cwd: URL) async throws -> ResidentDSHSessionHandle {
        opens += 1
        let next = make(opens); real = next
        return try await next.openSession(cwd: work)
    }
    func prompt(sessionID: String, blocks: [ResidentDSHPromptBlock]) async throws -> String {
        try await real!.prompt(sessionID: sessionID, blocks: blocks)
    }
    func cancelActivePrompt() { real?.cancelActivePrompt() }
    func awaitCancellationSettled() async { await real?.awaitCancellationSettled() }
    func close() { real?.close() }
}

@main struct Tests {
    @MainActor static func main() async throws {
        // Overall watchdog: the suite must end far below this bound.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            print("FAIL: overall test watchdog timeout (90s)")
            exit(1)
        }
        defer { watchdog.cancel() }
        var count = 0
        func check(_ value: Bool, _ label: String) {
            count += 1
            if !value { fatalError("FAIL: " + label) }
        }
        @MainActor func waitFor(_ condition: @MainActor () -> Bool, seconds: Double, _ label: String) async {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            check(condition(), label + " (bounded wait \(seconds)s)")
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmgn-dsh-transport-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        func locatePython3() -> URL? {
            for candidate in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
            return nil
        }
        func stateLines(_ state: URL) -> [String] {
            guard let text = try? String(contentsOf: state, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").map(String.init)
        }
        func pidGone(_ pid: Int32) -> Bool {
            kill(pid, 0) != 0 && errno == ESRCH
        }

        // The fake server is selected by the first line of the file passed as
        // --config: "block", "noread" or "chat". Real process behavior (pid,
        // prompts, cancel notifications) is appended to "<config>.state".
        let fakeScript = #"""
        import sys, json, os, time, select

        args = sys.argv[1:]
        config = args[args.index("--config") + 1] if "--config" in args else "/tmp/fake-acp"
        state_path = config + ".state"
        mode = open(config).readline().strip()

        def log(message):
            with open(state_path, "a") as handle:
                handle.write(message + "\n")

        def send(obj):
            sys.stdout.write(json.dumps(obj) + "\n")
            sys.stdout.flush()

        log("pid " + str(os.getpid()))

        def handle_initialize(req):
            send({"jsonrpc": "2.0", "id": req["id"], "result": {
                "protocolVersion": 1,
                "agentInfo": {"name": "fake-acp", "version": "0"},
                "agentCapabilities": {"promptCapabilities": {"image": True, "audio": False, "embeddedContext": False}},
                "authMethods": [],
            }})

        def handle_session_new(req):
            send({"jsonrpc": "2.0", "id": req["id"], "result": {"sessionId": sid_holder[0]}})

        def chunk(sid, text):
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": sid,
                "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}},
            }})

        sessions = []
        sid_holder = [""]

        if mode == "block":
            while True:
                time.sleep(1)

        if mode == "noread":
            for line in sys.stdin:
                req = json.loads(line)
                if req.get("method") == "initialize":
                    handle_initialize(req)
                elif req.get("method") == "session/new":
                    sid_holder[0] = "sess-1"
                    sessions.append(sid_holder[0])
                    log("session " + sid_holder[0])
                    handle_session_new(req)
                    break
            # Stop reading entirely: a large prompt write must block in the IO
            # queue while the client stays responsive to cancellation.
            while True:
                time.sleep(1)

        prompts_seen = 0
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except ValueError:
                continue
            method = req.get("method")
            if method == "initialize":
                handle_initialize(req)
                continue
            if method == "session/new":
                sid_holder[0] = "sess-%d" % (len(sessions) + 1)
                sessions.append(sid_holder[0])
                log("session " + sid_holder[0])
                handle_session_new(req)
                continue
            if method == "session/cancel":
                log("cancel-notification")
                continue
            if method != "session/prompt":
                continue
            prompts_seen += 1
            sid = req["params"]["sessionId"]
            log("prompt %s" % sid)
            if mode == "late-cancel":
                release = config + ".release" + str(prompts_seen)
                cancelled = False
                while not os.path.exists(release):
                    if select.select([sys.stdin], [], [], 0.01)[0]:
                        notice = json.loads(sys.stdin.readline())
                        if notice.get("method") == "session/cancel":
                            log("cancelled %s" % sid)
                            cancelled = True
                            break
                chunk(sid, "reply-%d" % prompts_seen)
                send({"jsonrpc": "2.0", "id": req["id"], "result": {"stopReason": "cancelled" if cancelled else "end_turn"}})
                continue
            if mode == "answer":
                chunk(sid, "reconnected")
                send({"jsonrpc": "2.0", "id": req["id"], "result": {"stopReason": "end_turn"}})
                continue
            if prompts_seen == 1:
                chunk(sid, "first")
                log("await-cancel %s" % sid)
                cancelled = False
                for inner in sys.stdin:
                    inner = inner.strip()
                    if not inner:
                        continue
                    notice = json.loads(inner)
                    if notice.get("method") == "session/cancel":
                        cancelled = True
                        log("cancelled %s" % sid)
                        break
                if mode == "delay-cancel":
                    time.sleep(0.25)
                send({"jsonrpc": "2.0", "id": req["id"], "result": {"stopReason": "cancelled" if cancelled else "end_turn"}})
            elif prompts_seen == 2:
                chunk("sess-foreign", "FOREIGN")
                chunk(sid, "second")
                send({"jsonrpc": "2.0", "id": req["id"], "result": {"stopReason": "end_turn"}})
            else:
                # One single stdout write: the result line and a same-session
                # late chunk arrive batched in the same read, so the client
                # routes them back to back before any defer can run.
                sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": {"stopReason": "end_turn"}}) + "\n")
                sys.stdout.write(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "LATE"}}}}) + "\n")
                sys.stdout.flush()
        """#

        func makeConnectorConfig(_ mode: String) -> (config: URL, state: URL) {
            let config = work.appendingPathComponent("fake-\(mode)-\(UUID()).cordis.yml")
            let state = URL(fileURLWithPath: config.path + ".state")
            try? Data((mode + "\n").utf8).write(to: config)
            return (config, state)
        }

        guard let python = locatePython3() else {
            print("FAIL: python3 not found for the fake ACP subprocess")
            exit(1)
        }
        let fake = work.appendingPathComponent("fake_acp.py")
        try Data(fakeScript.utf8).write(to: fake)

        var cancellationFailures: [String] = []
        // Cancellation can arrive after request's first cancellation check,
        // before its continuation is registered. Do not send that request.
        do {
            let (config, state) = makeConnectorConfig("answer")
            let connector = ResidentDSHConnector(nodeExecutable: python, entryPoint: fake,
                compositionFileURL: config, requestTimeout: 5, cancellationGrace: 0.1)
            let handle = try await connector.openSession(cwd: work)
            TransportAdmissionCancellation.armed = true
            let cancelled = Task { try await connector.prompt(sessionID: handle.sessionID, blocks: [.text("cancel before registration")]) }
            _ = try? await cancelled.value
            try await Task.sleep(for: .milliseconds(100))
            if stateLines(state).contains(where: { $0.hasPrefix("prompt ") }) {
                cancellationFailures.append("request cancelled before registration was sent to peer")
            }
            connector.close()
        }
        // A received response settles the wire request before prompt's defer
        // releases its lease. Manual cancel must still make immediate reuse
        // wait for that cleanup, without a grace timeout closing the session.
        do {
            let (config, _) = makeConnectorConfig("answer")
            let connector = ResidentDSHConnector(nodeExecutable: python, entryPoint: fake,
                compositionFileURL: config, requestTimeout: 5, cancellationGrace: 0.1)
            let handle = try await connector.openSession(cwd: work)
            TransportPromptSettlementGate.armed = true
            let first = Task { try await connector.prompt(sessionID: handle.sessionID, blocks: [.text("first")]) }
            await waitFor({ TransportPromptSettlementGate.entered }, seconds: 5, "response arrived before prompt cleanup")
            connector.cancelActivePrompt()
            var reuseReady = false
            let waiting = Task { await connector.awaitCancellationSettled(); reuseReady = true }
            try await Task.sleep(for: .milliseconds(150))
            if reuseReady { cancellationFailures.append("cancelled prompt lease was reused before cleanup") }
            if !connector.isUsable { cancellationFailures.append("settled response was hard-closed before prompt cleanup") }
            TransportPromptSettlementGate.release()
            _ = try? await first.value
            await waiting.value
            if connector.isUsable {
                let reply = try await connector.prompt(sessionID: handle.sessionID, blocks: [.text("next")])
                check(reply == "reconnected", "cancel after response preserves native session")
            }
            connector.close()
        }
        // A task cancelled before admission must not launch an ACP process.
        do {
            let (config, state) = makeConnectorConfig("answer")
            let connector = ResidentDSHConnector(nodeExecutable: python, entryPoint: fake,
                compositionFileURL: config, requestTimeout: 5, cancellationGrace: 0.1)
            var start: CheckedContinuation<Void, Never>?
            let opening = Task {
                await withCheckedContinuation { start = $0 }
                return try await connector.openSession(cwd: work)
            }
            await waitFor({ start != nil }, seconds: 5, "open task is held before admission")
            opening.cancel()
            start?.resume()
            do { _ = try await opening.value; check(false, "cancelled open must throw") }
            catch { check(error is CancellationError, "cancelled open surfaces cancellation") }
            try await Task.sleep(for: .milliseconds(250))
            let launched = stateLines(state).contains { $0.hasPrefix("pid ") }
            connector.close()
            if launched { cancellationFailures.append("already-cancelled open launched an ACP subprocess") }
        }
        // There is no ACP request while the host is running a world tool.
        // Cancelling at that boundary must leave the idle session reusable.
        do {
            let (config, state) = makeConnectorConfig("answer")
            let connector = ResidentDSHConnector(nodeExecutable: python, entryPoint: fake,
                compositionFileURL: config, requestTimeout: 5, cancellationGrace: 0.1)
            let handle = try await connector.openSession(cwd: work)
            _ = try await connector.prompt(sessionID: handle.sessionID, blocks: [.text("before tool")])
            connector.cancelActivePrompt()
            try await Task.sleep(for: .milliseconds(300))
            if !connector.isUsable {
                cancellationFailures.append("idle cancellation killed a healthy session after grace")
            } else {
                let reply = try await connector.prompt(sessionID: handle.sessionID, blocks: [.text("after tool")])
                check(reply == "reconnected", "idle cancellation preserves subsequent native prompts")
            }
            check(!stateLines(state).contains("cancel-notification"), "idle cancellation sends no wire notification")
            connector.close()
        }
        // Hold the old task's callback until its response has settled and the
        // next request has reached the real subprocess. Its cancellation must
        // still belong to the old request, regardless of executor scheduling.
        do {
            let (config, state) = makeConnectorConfig("late-cancel")
            let connector = ResidentDSHConnector(nodeExecutable: python, entryPoint: fake,
                compositionFileURL: config, requestTimeout: 5, cancellationGrace: 0.1)
            let handle = try await connector.openSession(cwd: work)
            TransportCancellationGate.armed = true
            let first = Task { try await connector.prompt(sessionID: handle.sessionID, blocks: [.text("first")]) }
            await waitFor({ stateLines(state).filter { $0.hasPrefix("prompt ") }.count == 1 }, seconds: 5,
                "first prompt reached peer before delayed cancellation")
            first.cancel()
            await waitFor({ TransportCancellationGate.entered }, seconds: 5, "old cancellation delivery is gated")
            try Data().write(to: URL(fileURLWithPath: config.path + ".release1"))
            _ = try? await first.value
            let second = Task { try await connector.prompt(sessionID: handle.sessionID, blocks: [.text("second")]) }
            await waitFor({ stateLines(state).filter { $0.hasPrefix("prompt ") }.count == 2 }, seconds: 5,
                "next prompt reached peer before old cancellation delivery")
            TransportCancellationGate.release()
            await waitFor({ TransportCancellationGate.delivered }, seconds: 5, "old callback was delivered")
            try await Task.sleep(for: .milliseconds(150))
            try Data().write(to: URL(fileURLWithPath: config.path + ".release2"))
            do {
                let reply = try await second.value
                if reply != "reply-2" { cancellationFailures.append("old cancellation changed next reply") }
            } catch {
                cancellationFailures.append("old cancellation cancelled the next prompt: \(error)")
            }
            if stateLines(state).contains(where: { $0.hasPrefix("cancelled ") }) {
                cancellationFailures.append("old cancellation sent session/cancel for the next prompt")
            }
            connector.close()
        }
        for failure in cancellationFailures { print("FAIL: " + failure) }
        if !cancellationFailures.isEmpty { exit(1) }

        // ── 1) Blocked stdin + large image write: Task.cancel returns within
        // the grace bound and the owned subprocess exits. ──
        do {
            let (config, state) = makeConnectorConfig("noread")
            let connector = ResidentDSHConnector(
                nodeExecutable: python, entryPoint: fake, compositionFileURL: config,
                requestTimeout: 10, cancellationGrace: 1
            )
            let handle = try await connector.openSession(cwd: work)
            check(handle.imagePromptCapability, "fake ACP handshake advertises image capability")
            await waitFor({ stateLines(state).contains { $0.hasPrefix("pid ") } }, seconds: 5,
                          "fake subprocess reported its pid")
            guard let pidLine = stateLines(state).first(where: { $0.hasPrefix("pid ") }),
                  let pid = Int32(pidLine.dropFirst(4)) else {
                fatalError("FAIL: missing fake pid")
            }
            // 12 MB of image bytes → ~16 MB base64 frame: far beyond any pipe
            // buffer, so the write genuinely blocks while nobody reads.
            let bigImage = ResidentDSHImageBlock(data: Data(count: 12_000_000), mimeType: "image/png")
            let promptTask = Task {
                try await connector.prompt(
                    sessionID: handle.sessionID,
                    blocks: [.image(bigImage), .text("看这张大图")]
                )
            }
            try await Task.sleep(nanoseconds: 400_000_000)
            let start = Date()
            promptTask.cancel()
            do {
                _ = try await promptTask.value
                check(false, "a blocked-stdin prompt must not succeed after cancellation")
            } catch {
                check(error is CancellationError,
                      "cancelled blocked prompt surfaces CancellationError (got \(error))")
            }
            let elapsed = Date().timeIntervalSince(start)
            check(elapsed < 6, "Task.cancel returns within the bounded upper bound (took \(elapsed)s)")
            await waitFor({ pidGone(pid) }, seconds: 5, "owned subprocess exits after teardown")
            check(!connector.isUsable, "the grace-torn-down connector reports unusable")
        }

        // ── 2+3) Chat fake: graceful cancellation survives beyond the grace
        // window on the same session; cross-session and late chunks never
        // pollute replies. ──
        do {
            let (config, state) = makeConnectorConfig("chat")
            let connector = ResidentDSHConnector(
                nodeExecutable: python, entryPoint: fake, compositionFileURL: config,
                requestTimeout: 10, cancellationGrace: 1
            )
            let handle = try await connector.openSession(cwd: work)

            let firstTask = Task {
                try await connector.prompt(sessionID: handle.sessionID, blocks: [.text("第一轮")])
            }
            await waitFor({ stateLines(state).contains { $0.hasPrefix("await-cancel") } },
                          seconds: 5, "fake is waiting for the session/cancel notification")

            // An overlapping prompt is rejected before touching shared state:
            // no grace cleared, no activeSessionID/replyChunks overwritten, and
            // the fake never sees a second prompt while the first is in flight.
            var conflictRejected = false
            do {
                _ = try await connector.prompt(sessionID: handle.sessionID, blocks: [.text("并发请求")])
                check(false, "an overlapping prompt must be rejected")
            } catch let error as ResidentDSHTransportError {
                if case .promptConflict = error { conflictRejected = true }
            } catch {}
            check(conflictRejected, "the overlapping prompt rejects with promptConflict")
            check(stateLines(state).filter { $0.hasPrefix("prompt ") }.count == 1,
                  "the fake saw no second prompt from the rejected overlap")

            let cancelStart = Date()
            firstTask.cancel()
            do {
                _ = try await firstTask.value
                check(false, "the cancelled turn must not return a reply")
            } catch {
                check(error is CancellationError,
                      "graceful cancelled stopReason surfaces CancellationError (got \(error))")
            }
            let cancelElapsed = Date().timeIntervalSince(cancelStart)
            check(cancelElapsed < 6,
                  "the first turn still settles within its original grace bound (took \(cancelElapsed)s)")
            check(connector.isUsable, "a confirmed graceful cancellation keeps the connector usable")

            // Outlive the 1s grace window: it must have been disarmed by the
            // settlement, not fire and hard-close the healthy session.
            try await Task.sleep(nanoseconds: 2_500_000_000)
            check(connector.isUsable, "the grace window did not fire after a settled cancellation")

            var observedDeltas: [String] = []
            let second = try await connector.prompt(sessionID: handle.sessionID, blocks: [.text("第二轮")],
                onTextDelta: { observedDeltas.append($0) })
            check(second == "second",
                  "cross-session chunk is filtered out of the reply (got \(second.debugDescription))")
            check(observedDeltas == ["second"], "observer receives only genuine active-session text chunks")
            let third = try await connector.prompt(sessionID: handle.sessionID, blocks: [.text("第三轮")],
                onTextDelta: { observedDeltas.append($0) })
            check(third == "",
                  "a late chunk after settlement cannot pollute the reply (got \(third.debugDescription))")
            check(observedDeltas == ["second"], "observer filters same-session chunks arriving after prompt settlement")

            let promptSessions = stateLines(state)
                .filter { $0.hasPrefix("prompt ") }
                .map { String($0.dropFirst("prompt ".count)) }
            check(promptSessions == [handle.sessionID, handle.sessionID, handle.sessionID],
                  "all turns stayed inside the same native session (\(promptSessions))")
            check(stateLines(state).contains { $0.hasPrefix("cancelled ") },
                  "the fake observed the real session/cancel notification")
            connector.close()
        }

        // The same configured per-request deadline also bounds native ACP,
        // independently of the longer whole-turn deadline in the service.
        do {
            let (config, state) = makeConnectorConfig("noread")
            let connector = ResidentDSHConnector(nodeExecutable: python, entryPoint: fake,
                compositionFileURL: config, requestTimeout: 1, cancellationGrace: 1)
            let handle = try await connector.openSession(cwd: work)
            let started = Date()
            var timedOut = false
            do { _ = try await connector.prompt(sessionID: handle.sessionID, blocks: [.text("等待超时")]) }
            catch ResidentDSHTransportError.timedOut { timedOut = true }
            check(timedOut && Date().timeIntervalSince(started) < 4, "native prompt honors its configured request deadline")
            check(!connector.isUsable, "native timeout retires the timed-out connector")
            if let pidLine = stateLines(state).first(where: { $0.hasPrefix("pid ") }),
               let pid = Int32(pidLine.dropFirst(4)) {
                await waitFor({ pidGone(pid) }, seconds: 5, "native request timeout reaps its owned child")
            } else { check(false, "native timeout fixture reported its owned pid") }
        }

        for graceful in [true, false] {
            let (firstConfig, firstState) = makeConnectorConfig(graceful ? "delay-cancel" : "noread")
            let (newConfig, _) = makeConnectorConfig("answer")
            let wrapper = ReopeningFixtureConnector(work: work) { index in
                ResidentDSHConnector(nodeExecutable: python, entryPoint: fake,
                    compositionFileURL: index == 1 ? firstConfig : newConfig,
                    requestTimeout: 10, cancellationGrace: 0.5)
            }
            let suite = "gmgn-native-cancel-next-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(AgentConversationBackendID.dsh.rawValue, forKey: AgentConversationPreferenceKeys.selectedBackend)
            let service = AgentConversationService(locator: FixtureDSHLocator(), defaults: defaults,
                residentDSHImageConnector: wrapper)
            let first = Task { try await service.send("first") }
            await waitFor({ stateLines(firstState).contains { $0.hasPrefix(graceful ? "await-cancel" : "session ") } },
                seconds: 5, "real native first prompt is ready for cancellation")
            if !graceful { try await Task.sleep(for: .milliseconds(50)) }
            service.cancel()
            var nextReply: String?
            do { nextReply = try await service.send("immediately next") }
            catch { check(false, "immediate next native request failed: \(error)") }
            check(nextReply == (graceful ? "second" : "reconnected"), "immediate next request waits for native cancellation to settle")
            check(wrapper.opens == (graceful ? 1 : 2), "graceful cancel preserves session; forced close reconnects")
            do { _ = try await first.value; check(false, "old native request cannot return a reply") }
            catch AgentConversationError.cancelled {}
            service.resetSession()
        }

        print("PASS: \(count) resident DSH transport checks")
    }
}
"""##

let main = build.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
// Insert a scheduling barrier only into the copied cancellation callback;
// never add test-only API or scheduling behavior to production.
var scheduledTransport = transportSource
guard let registration = scheduledTransport.range(of: "try await withCheckedThrowingContinuation { continuation in") else {
    fatalError("FAIL: request registration boundary not found")
}
scheduledTransport.insert(contentsOf: "\n                TransportAdmissionCancellation.cancelIfArmed()", at: registration.upperBound)
guard let handler = scheduledTransport.range(of: "} onCancel: { [weak self] in"),
      let delivery = scheduledTransport.range(of: "Task { @MainActor [weak self] in",
          range: handler.upperBound..<scheduledTransport.endIndex) else {
    fatalError("FAIL: cancellation scheduling boundary not found")
}
scheduledTransport.insert(contentsOf: " await TransportCancellationGate.waitIfArmed();", at: delivery.upperBound)
guard let response = scheduledTransport.range(of: "let data = try await request(method: \"session/prompt\", params: payload)") else {
    fatalError("FAIL: prompt settlement boundary not found")
}
scheduledTransport.insert(contentsOf: "\n        await TransportPromptSettlementGate.waitIfArmed()", at: response.upperBound)
let transportCopy = build.appendingPathComponent("ResidentDSHTransport.swift")
try scheduledTransport.write(to: transportCopy, atomically: true, encoding: .utf8)
let binary = build.appendingPathComponent("test")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
let transportAgentFiles = [
    "CodexCLI", "AgentConversationService", "ResidentCodexTransport", "ResidentCodexPolicy",
    "ResidentCodexAgent", "ResidentSteeringDelivery", "ResidentDSHConfiguration",
    "ResidentStateClient", "ResidentMemoryClient", "ResidentConversationMemory",
    "ResidentDSHAgentToolBridge", "ResidentDSHHostToolsBridge",
    "ResidentClaudeToolBridge", "ResidentClaudeProcessRunner",
].map { root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/\($0).swift").path }
let transportVisionFile = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentVisionCapture.swift")
let transportRetryFile = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/RetryBackoff.swift")
compile.arguments = ["-swift-version", "6", "-parse-as-library", "-j1"] + transportAgentFiles
    + [transportVisionFile.path, transportRetryFile.path, transportCopy.path, main.path, "-o", binary.path]
try compile.run()
let compileDeadline = Date().addingTimeInterval(120)
while compile.isRunning && Date() < compileDeadline {
    try await Task.sleep(nanoseconds: 100_000_000)
}
if compile.isRunning {
    compile.terminate()
    print("FAIL: transport test compile exceeded 120s")
    exit(124)
}
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }

let test = Process()
test.executableURL = binary
try test.run()
let runDeadline = Date().addingTimeInterval(90)
while test.isRunning && Date() < runDeadline {
    try await Task.sleep(nanoseconds: 100_000_000)
}
if test.isRunning {
    test.terminate()
    print("FAIL: transport test execution exceeded 90s")
    exit(124)
}
test.waitUntilExit()
exit(test.terminationStatus)
