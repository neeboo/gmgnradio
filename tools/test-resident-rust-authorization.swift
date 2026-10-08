// Private hostless harness compiling the production lease with inert world stubs.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-rust-authorization-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Tests.swift")
let executable = temporary.appendingPathComponent("tests")
let harness = #"""
import Foundation
struct RealtimeDJToolCall { let id: String; let name: String; let argumentsJSON: Data }
struct RealtimeDJToolResult: Equatable { let callID: String; let resultJSON: Data; let isError: Bool }
struct Parameter { let type: String }
struct Capability { let name: String; let parameters: [String: Parameter]; let requiredParameters: [String] }
enum WorldAgentToolContract { static let capabilities = [Capability(name: "inspect_world", parameters: [:], requiredParameters: [])] }
struct Snapshot { var worldID = "w"; var revision: UInt64 = 1 }
struct Activity { let id: String }
struct Manifest { let activities: [Activity] = [] }
@MainActor final class Context { var snapshot = Snapshot(); let manifest = Manifest() }
@MainActor final class WorldAgentToolDispatcher {
    let context: Context
    var count = 0
    init(_ context: Context) { self.context = context }
    var providerTools: [[String: Any]] { [["function": ["name": "inspect_world", "parameters": ["type": "object"]]]] }
    func handle(_ call: RealtimeDJToolCall) async -> RealtimeDJToolResult {
        count += 1
        return RealtimeDJToolResult(callID: call.id, resultJSON: Data("{\"ok\":true}".utf8), isError: false)
    }
}
enum RetryDecision { case retrySameApproach, needsHuman, changeApproach(String), structural(String), handOff(String) }
struct ResidentRetryLedger {
    mutating func noteSuccess() {}
    mutating func noteFailure(tool: String, code: String, at: Date) -> RetryDecision { .retrySameApproach }
}
enum RustCodexSessionClient {
    typealias Call = @Sendable (String, Data) throws -> Data
    struct Identity: Sendable, Equatable { let worldID: String; let residentScope: String; let hostSessionID: String; let runID: String; let eventID: String }
    struct PendingTool: Sendable { let identity: Identity; let threadID: String; let turnID: String; let callID: String; let toolName: String; let arguments: Data; let phase: String; let operationID: String? }
}
enum RustDSHSessionClient {
    typealias Identity = RustCodexSessionClient.Identity
    typealias Call = RustCodexSessionClient.Call
    struct PendingTool: Sendable { let identity: Identity; let acpSessionID: String; let callID: String; let toolName: String; let arguments: Data; let phase: String; let operationID: String? }
}
struct RustResidentDSHToolBinding: Sendable {
    let identity: RustDSHSessionClient.Identity
    let transport: RustDSHSessionClient.Call
    let endpointURL: URL
    let environment: [String: String]
    let effects: [String: String]
    let authorize: @MainActor @Sendable (RustDSHSessionClient.PendingTool) async throws -> String?
}
enum RustClaudeSessionClient {
    typealias Identity = RustCodexSessionClient.Identity
    typealias Call = RustCodexSessionClient.Call
    struct PendingTool: Sendable { let identity: Identity; let round: Int; let callID: String; let toolName: String; let arguments: Data; let phase: String; let operationID: String? }
}
enum ResidentClaudeEnvironment {
    static let passthroughKeys = ["PATH", "TMPDIR", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL"]
    static let credentialKey = "ANTHROPIC_API_KEY"
}
struct RustResidentClaudeToolBinding: Sendable {
    let identity: RustClaudeSessionClient.Identity
    let transport: RustClaudeSessionClient.Call
    let endpointURL: URL
    let adapterExecutableURL: URL
    let environment: [String: String]
    let effects: [String: String]
    let authorize: @MainActor @Sendable (RustClaudeSessionClient.PendingTool) async throws -> String?
}
struct RustResidentToolBinding: Sendable {
    let identity: RustCodexSessionClient.Identity
    let transport: RustCodexSessionClient.Call
    let environment: [String: String]
    let effects: [String: String]
    let authorize: @MainActor @Sendable (RustCodexSessionClient.PendingTool) async throws -> String?
}
struct RustResidentSchedulerClient {
    let worldID: String; let residentScope: String
    struct Ticket { let eventID: String; let runID: UUID; let hostSessionID: String }
}
enum HarnessError: Error { case unexpectedTransport }
final class TaskdHTTPAuthorityClient: @unchecked Sendable {
    init(endpointFile: String, helperPath: String, allowsLaunching: Bool, timeout: Double) {
        precondition(endpointFile == "/private-test/no-real-endpoint" && helperPath.isEmpty && !allowsLaunching)
    }
    func call(method: String, params: [String: Any]) throws -> [String: Any] { throw HarnessError.unexpectedTransport }
    func validatedControlURL() throws -> URL { URL(string: "http://127.0.0.1:1/rpc")! }
}
enum ResidentCodexPolicy { static func environment(from source: [String: String]) -> [String: String] { [:] } }
@MainActor final class State { var current = true; var clock = Date(timeIntervalSince1970: 100); var decision = "step"; var handled = 0; var scope = UUID(); var revisionOverride: UInt64?; var dispatch: ResidentWorldToolSession.RustDispatchAuthority? }
@main struct Tests {
    @MainActor static func main() async throws {
        let context = Context(), dispatcher = WorldAgentToolDispatcher(context), state = State()
        let extra = ResidentWorldToolSession.AdditionalTool(name: "place_test", description: "inert test placement",
            inputSchema: ["type": "object", "properties": ["x": ["type": "number"]]],
            validate: { Set($0.keys) == ["x"] && $0["x"] is NSNumber },
            handle: { id, _ in state.handled += 1; state.dispatch = ResidentWorldToolSession.rustDispatchAuthority; return .init(callID: id, resultJSON: Data("{\"ok\":true}".utf8), isError: false) })
        let lease = ResidentWorldToolSession(scopeID: state.scope, worldID: "w", dispatcher: dispatcher,
            deadline: Date(timeIntervalSince1970: 200), now: { state.clock }, isCurrent: { state.current },
            additionalTools: [extra], maximumCalls: 2, rustOperationAuthority: { _, _ in
                .init(scopeID: state.scope, worldID: "w", intentID: "real-host-run", decisionID: state.decision,
                      factsRevision: state.revisionOverride ?? context.snapshot.revision)
            })
        let args = Data("{\"x\":1}".utf8)
        let op = lease.authorizeRustOperation(callID: "model-call-1", name: "place_test", argumentsJSON: args)!
        precondition(op != "model-call-1" && state.handled == 0, "preflight cannot execute or accept model identity")
        precondition(lease.authorizeRustOperation(callID: "model-call-1", name: "place_test", argumentsJSON: args) == op)
        context.snapshot.revision += 1
        precondition(lease.authorizeRustOperation(callID: "replacement-model-call", name: "place_test", argumentsJSON: args) == op, "revision/call-ID changes do not mint another write")
        precondition(lease.authorizeRustOperation(callID: "model-call-1", name: "place_test", argumentsJSON: Data("{\"x\":2}".utf8)) == nil)
        precondition(lease.authorizeRustOperation(callID: "different-call", name: "place_test", argumentsJSON: Data("{\"x\":2}".utf8)) == nil)
        precondition(lease.authorizeRustOperation(callID: "bad", name: "place_test", argumentsJSON: Data("{\"x\":1,\"operationID\":\"model-grant\"}".utf8)) == nil)
        precondition(lease.authorizeRustOperation(callID: "bad", name: "unregistered", argumentsJSON: args) == nil)
        let first = await lease.callRustOperation(operationID: op, callID: "model-call-1", name: "place_test", argumentsJSON: args)
        let replay = await lease.callRustOperation(operationID: op, callID: "replacement-model-call", name: "place_test", argumentsJSON: args)
        precondition(!first.isError && !replay.isError && replay.callID == "replacement-model-call" && state.handled == 1)
        let forged = await lease.callRustOperation(operationID: "model-forged", callID: "model-call-1", name: "place_test", argumentsJSON: args)
        precondition(forged.isError && state.handled == 1)
        lease.markRustOperationUnknown(operationID: op)
        precondition(lease.authorizeRustOperation(callID: "retry-after-disconnect", name: "place_test", argumentsJSON: args) == nil)
        let unknown = await lease.callRustOperation(operationID: op, callID: "model-call-1", name: "place_test", argumentsJSON: args)
        precondition(unknown.isError && state.handled == 1)
        state.decision = "second-step"
        precondition(lease.authorizeRustOperation(callID: "second", name: "place_test", argumentsJSON: args) != nil)
        state.decision = "third-step"
        precondition(lease.authorizeRustOperation(callID: "third", name: "place_test", argumentsJSON: args) == nil, "execution plus reservation exhaust budget")
        // Guard checks use a fresh, unexhausted lease so budget denial cannot mask
        // a broken cancellation, world, revision, scope, or deadline guard.
        let guardLease = ResidentWorldToolSession(scopeID: state.scope, worldID: "w", dispatcher: dispatcher,
            deadline: Date(timeIntervalSince1970: 200), now: { state.clock }, isCurrent: { state.current },
            additionalTools: [extra], maximumCalls: 64, rustOperationAuthority: { _, _ in
                .init(scopeID: state.scope, worldID: "w", intentID: "real-host-run", decisionID: "guard-step",
                      factsRevision: state.revisionOverride ?? context.snapshot.revision)
            })
        precondition(guardLease.authorizeRustOperation(callID: "good", name: "place_test", argumentsJSON: args) != nil)
        state.current = false
        precondition(guardLease.authorizeRustOperation(callID: "stale", name: "place_test", argumentsJSON: args) == nil)
        state.current = true; context.snapshot.worldID = "other-world"
        precondition(guardLease.authorizeRustOperation(callID: "wrong-world", name: "place_test", argumentsJSON: args) == nil)
        context.snapshot.worldID = "w"; state.revisionOverride = 0
        precondition(guardLease.authorizeRustOperation(callID: "stale-facts", name: "place_test", argumentsJSON: args) == nil)
        state.revisionOverride = nil
        state.current = true; state.clock = Date(timeIntervalSince1970: 201)
        precondition(guardLease.authorizeRustOperation(callID: "expired", name: "place_test", argumentsJSON: args) == nil)
        state.clock = Date(timeIntervalSince1970: 100); state.scope = UUID()
        precondition(guardLease.authorizeRustOperation(callID: "wrong-scope", name: "place_test", argumentsJSON: args) == nil)
        guardLease.cancel(); lease.cancel()
        precondition(guardLease.authorizeRustOperation(callID: "cancelled", name: "place_test", argumentsJSON: args) == nil)
        let old = ResidentWorldToolSession(scopeID: UUID(), worldID: "w", dispatcher: dispatcher, deadline: .distantFuture, isCurrent: { true })
        precondition(old.authorizeRustOperation(callID: "none", name: "inspect_world", argumentsJSON: Data("{}".utf8)) == nil)
        let legacy = await old.call(requestID: "old-call", name: "inspect_world", argumentsJSON: Data("{}".utf8))
        precondition(!legacy.isError && dispatcher.count == 1, "legacy call remains unchanged without Rust authority")
        // Compile and execute the shipping factory with only its external HTTP/
        // identity declarations stubbed. Production factory and lease both run.
        let factoryScope = UUID()
        let firstCanonical = try JSONSerialization.data(withJSONObject: ["x": 1, "target": "chair"], options: [.sortedKeys])
        let reorderedCanonical = try JSONSerialization.data(withJSONObject: ["target": "chair", "x": 1], options: [.sortedKeys])
        let writeOne = RustResidentToolBindingFactory.decision(scopeID: factoryScope, worldID: "w", revision: 1, name: "place_test", canonical: firstCanonical)
        let writeTwo = RustResidentToolBindingFactory.decision(scopeID: factoryScope, worldID: "w", revision: 2, name: "place_test", canonical: reorderedCanonical)
        precondition(writeOne.intentID == factoryScope.uuidString && writeOne.decisionID == writeTwo.decisionID, "write fingerprint ignores fact revision and canonical key order")
        let readOne = RustResidentToolBindingFactory.decision(scopeID: factoryScope, worldID: "w", revision: 1, name: "read_music_state", canonical: Data("{}".utf8))
        let readTwo = RustResidentToolBindingFactory.decision(scopeID: factoryScope, worldID: "w", revision: 2, name: "read_music_state", canonical: Data("{}".utf8))
        precondition(readOne.decisionID != readTwo.decisionID, "read may reobserve new facts")
        let factoryLease = ResidentWorldToolSession(scopeID: factoryScope, worldID: "w", dispatcher: dispatcher,
            deadline: .distantFuture, isCurrent: { true }, additionalTools: [extra], rustOperationAuthority: { name, canonical in
                RustResidentToolBindingFactory.decision(scopeID: factoryScope, worldID: "w", revision: context.snapshot.revision, name: name, canonical: canonical)
            })
        let claim = (scheduler: RustResidentSchedulerClient(worldID: "w", residentScope: "fixture"), ticket: RustResidentSchedulerClient.Ticket(eventID: "event", runID: factoryScope, hostSessionID: "host"))
        let factory = try RustResidentToolBindingFactory(session: factoryLease, claim: claim, endpointFile: "/private-test/no-real-endpoint")
        precondition(factory.binding.effects["place_test"] == "write", "unknown registered capabilities default to trusted write classification")
        let unauthorized = await factory.call(callID: "unapproved", name: "place_test", arguments: args)
        precondition(unauthorized.isError && state.handled == 1)
        func proposal(_ id: String, _ identity: RustCodexSessionClient.Identity? = nil, _ arguments: Data? = nil) -> RustCodexSessionClient.PendingTool {
            .init(identity: identity ?? factory.binding.identity, threadID: "thread", turnID: "turn", callID: id,
                  toolName: "place_test", arguments: arguments ?? args, phase: "authorize", operationID: "ignored-model-value")
        }
        let foreign = RustCodexSessionClient.Identity(worldID: "other", residentScope: "fixture", hostSessionID: "host", runID: factoryScope.uuidString, eventID: "event")
        let foreignGrant = try await factory.binding.authorize(proposal("wrong-identity", foreign))
        let invalidGrant = try await factory.binding.authorize(proposal("bad-args", nil, Data("{\"x\":1,\"extra\":true}".utf8)))
        precondition(foreignGrant == nil && invalidGrant == nil && state.handled == 1)
        let factoryOp = try await factory.binding.authorize(proposal("factory-call-1"))
        precondition(factoryOp != nil && factoryOp != "ignored-model-value" && state.handled == 1)
        let factoryResult = await factory.call(callID: "factory-call-1", name: "place_test", arguments: args)
        precondition(state.dispatch?.worldID == "w" && state.dispatch?.residentScope == "fixture"
            && state.dispatch?.hostSessionID == "host" && state.dispatch?.runID == factoryScope.uuidString
            && state.dispatch?.callID == "factory-call-1" && state.dispatch?.operationID == factoryOp
            && state.dispatch?.toolName == "place_test", "actual child dispatch inherits trusted ledger identity")
        precondition(ResidentWorldToolSession.rustDispatchAuthority == nil, "dispatch identity does not leak beyond its actual call")
        context.snapshot.revision += 1
        let retransmittedOp = try await factory.binding.authorize(proposal("factory-call-2"))
        let retransmittedResult = await factory.call(callID: "factory-call-2", name: "place_test", arguments: args)
        precondition(factoryOp == retransmittedOp && !factoryResult.isError && !retransmittedResult.isError && state.handled == 2, "factory routes to real session and deduplicates replacement calls")
        let dsh = try factory.dshBinding()
        precondition(dsh.identity == factory.binding.identity && dsh.effects == factory.binding.effects && dsh.endpointURL.host == "127.0.0.1")
        func dshProposal(_ id: String, _ identity: RustDSHSessionClient.Identity? = nil, _ arguments: Data? = nil) -> RustDSHSessionClient.PendingTool {
            .init(identity: identity ?? dsh.identity, acpSessionID: "private-acp-session", callID: id,
                  toolName: "place_test", arguments: arguments ?? args, phase: "authorize", operationID: "ignored-dsh-model-value")
        }
        // The ACP session name cannot substitute for the complete host identity.
        let wrongRun = RustDSHSessionClient.Identity(worldID: dsh.identity.worldID, residentScope: dsh.identity.residentScope,
            hostSessionID: dsh.identity.hostSessionID, runID: UUID().uuidString, eventID: dsh.identity.eventID)
        let wrongDSHGrant = try await dsh.authorize(dshProposal("dsh-wrong-run", wrongRun))
        let badDSHGrant = try await dsh.authorize(dshProposal("dsh-bad-args", nil, Data("{\"x\":1,\"extra\":true}".utf8)))
        precondition(wrongDSHGrant == nil && badDSHGrant == nil && state.handled == 2)
        context.snapshot.revision += 1
        let dshOp = try await dsh.authorize(dshProposal("dsh-call-1"))
        let dshResult = await factory.call(callID: "dsh-call-1", name: "place_test", arguments: args)
        precondition(dshOp == factoryOp && dshOp != "ignored-dsh-model-value" && !dshResult.isError && state.handled == 2, "DSH and CLI share the actual ledger, operation and first execution")
        let adapter = URL(fileURLWithPath: "/private-test/trusted-claude-adapter")
        let claude = try factory.claudeBinding(adapterExecutableURL: adapter, environment: ["LANG": "test-locale", "ANTHROPIC_API_KEY": "inert-fixture-value", "CLAUDE_CONFIG_DIR": "/ignored-old-config", "NODE_OPTIONS": "ignored-options", "OTHER": "ignored"])
        precondition(claude.adapterExecutableURL == adapter && claude.identity == factory.binding.identity && claude.effects == factory.binding.effects)
        precondition(Set(claude.environment.keys) == Set(["LANG", "ANTHROPIC_API_KEY"]) && claude.environment["LANG"] == "test-locale")
        func claudeProposal(_ id: String, _ identity: RustClaudeSessionClient.Identity? = nil, _ arguments: Data? = nil) -> RustClaudeSessionClient.PendingTool {
            .init(identity: identity ?? claude.identity, round: 1, callID: id, toolName: "place_test", arguments: arguments ?? args, phase: "authorize", operationID: "ignored-claude-model-value")
        }
        let wrongClaudeGrant = try await claude.authorize(claudeProposal("claude-wrong-run", wrongRun))
        let badClaudeGrant = try await claude.authorize(claudeProposal("claude-bad-args", nil, Data("{\"x\":1,\"extra\":true}".utf8)))
        precondition(wrongClaudeGrant == nil && badClaudeGrant == nil && state.handled == 2)
        context.snapshot.revision += 1
        let claudeOp = try await claude.authorize(claudeProposal("claude-call-1"))
        let claudeResult = await factory.call(callID: "claude-call-1", name: "place_test", arguments: args)
        precondition(claudeOp == factoryOp && !claudeResult.isError && state.handled == 2, "three backends share the actual business operation")
        factoryLease.markRustOperationUnknown(operationID: factoryOp!)
        let unknownGrant = try await factory.binding.authorize(proposal("factory-call-3"))
        let unknownResult = await factory.call(callID: "factory-call-3", name: "place_test", arguments: args)
        precondition(unknownGrant == nil && unknownResult.isError && state.handled == 2)
        let unknownDSHGrant = try await dsh.authorize(dshProposal("dsh-call-after-unknown"))
        let unknownDSHResult = await factory.call(callID: "dsh-call-after-unknown", name: "place_test", arguments: args)
        precondition(unknownDSHGrant == nil && unknownDSHResult.isError && state.handled == 2, "unknown write cannot be retried by switching CLI to DSH")
        let unknownClaudeGrant = try await claude.authorize(claudeProposal("claude-call-after-unknown"))
        let unknownClaudeResult = await factory.call(callID: "claude-call-after-unknown", name: "place_test", arguments: args)
        precondition(unknownClaudeGrant == nil && unknownClaudeResult.isError && state.handled == 2)
        print("PASS: resident Rust authorization host lease checks")
    }
}
"""#
try harness.write(to: program, atomically: true, encoding: .utf8)
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = ["-j1", "-parse-as-library", root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentWorldToolSession.swift").path, root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/RustResidentToolBindingFactory.swift").path, program.path, "-o", executable.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let tests = Process(); tests.executableURL = executable
try tests.run(); tests.waitUntilExit(); exit(tests.terminationStatus)
