import Foundation
import CryptoKit

/// Trusted host catalog and per-lease authorization owner. Unknown registered
/// capabilities are conservatively writes; the model cannot select effects.
@MainActor
final class RustResidentToolBindingFactory {
    static let readTools: Set<String> = ["read_world_state", "read_resident_state", "list_activities", "list_places", "list_cameras", "read_music_state", "list_music", "read_screen_state", "list_wish_tasks", "read_wish_task", "read_prop_inventory", "list_props", "recall_memory"]
    let binding: RustResidentToolBinding
    private let authority: TaskdHTTPAuthorityClient

    static func decision(scopeID: UUID, worldID: String, revision: UInt64, name: String, canonical: Data) -> ResidentWorldToolSession.HostBusinessDecision {
        var bytes = Data(name.utf8); bytes.append(0); bytes.append(canonical)
        if readTools.contains(name) { bytes.append(Data("|\(revision)".utf8)) }
        let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return .init(scopeID: scopeID, worldID: worldID, intentID: scopeID.uuidString,
            decisionID: fingerprint, factsRevision: revision)
    }

    init(session: ResidentWorldToolSession, claim: (scheduler: RustResidentSchedulerClient, ticket: RustResidentSchedulerClient.Ticket), endpointFile: String) throws {
        let identity = RustCodexSessionClient.Identity(worldID: claim.scheduler.worldID,
            residentScope: claim.scheduler.residentScope, hostSessionID: claim.ticket.hostSessionID,
            runID: claim.ticket.runID.uuidString, eventID: claim.ticket.eventID)
        let transport = TaskdHTTPAuthorityClient(endpointFile: endpointFile, helperPath: "", allowsLaunching: false, timeout: 5)
        authority = transport
        let schemas = try JSONSerialization.jsonObject(with: session.toolSchemasJSON) as? [[String: Any]] ?? []
        let effects = Dictionary(uniqueKeysWithValues: schemas.compactMap { row -> (String,String)? in
            guard let name = row["name"] as? String else { return nil }
            return (name, Self.readTools.contains(name) ? "read" : "write")
        })
        // A separate owner avoids capturing partially initialized self.
        let ledger = Ledger(session: session, identity: identity)
        self.ledger = ledger
        binding = .init(identity: identity, transport: { method, data in
            let params = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: params))
        }, environment: ResidentCodexPolicy.environment(from: ProcessInfo.processInfo.environment),
            effects: effects, authorize: { tool in ledger.authorize(tool) })
    }
    private let ledger: Ledger
    func dshBinding() throws -> RustResidentDSHToolBinding {
        .init(identity: binding.identity, transport: binding.transport,
            endpointURL: try authority.validatedControlURL(), environment: binding.environment,
            effects: binding.effects, authorize: { [ledger] tool in
                ledger.authorize(identity: tool.identity, callID: tool.callID, name: tool.toolName, arguments: tool.arguments)
            })
    }
    func claudeBinding(adapterExecutableURL: URL, environment source: [String: String]) throws -> RustResidentClaudeToolBinding {
        let allowed = Set(ResidentClaudeEnvironment.passthroughKeys + [ResidentClaudeEnvironment.credentialKey])
        let environment = source.filter { allowed.contains($0.key) }
        return .init(identity: binding.identity, transport: binding.transport,
            endpointURL: try authority.validatedControlURL(), adapterExecutableURL: adapterExecutableURL,
            environment: environment, effects: binding.effects, authorize: { [ledger] tool in
                ledger.authorize(identity: tool.identity, callID: tool.callID, name: tool.toolName, arguments: tool.arguments)
            })
    }
    func call(callID: String, name: String, arguments: Data) async -> RealtimeDJToolResult {
        await ledger.call(callID: callID, name: name, arguments: arguments)
    }
    @MainActor private final class Ledger {
        let session: ResidentWorldToolSession; let identity: RustCodexSessionClient.Identity
        var operations: [String:String] = [:]
        init(session: ResidentWorldToolSession, identity: RustCodexSessionClient.Identity) { self.session=session; self.identity=identity }
        func authorize(_ tool: RustCodexSessionClient.PendingTool) -> String? {
            authorize(identity: tool.identity, callID: tool.callID, name: tool.toolName, arguments: tool.arguments)
        }
        func authorize(identity incoming: RustCodexSessionClient.Identity, callID: String, name: String, arguments: Data) -> String? {
            guard incoming == identity, let operation = session.authorizeRustOperation(callID: callID, name: name, argumentsJSON: arguments) else { return nil }
            operations[callID] = operation; return operation
        }
        func call(callID: String, name: String, arguments: Data) async -> RealtimeDJToolResult {
            guard let operation = operations[callID] else {
                return .init(callID: callID, resultJSON: Data("{\"error\":\"rust_operation_not_authorized\"}".utf8), isError: true)
            }
            let dispatch = ResidentWorldToolSession.RustDispatchAuthority(
                worldID: identity.worldID, residentScope: identity.residentScope,
                hostSessionID: identity.hostSessionID, runID: identity.runID,
                callID: callID, operationID: operation, toolName: name)
            return await ResidentWorldToolSession.$rustDispatchAuthority.withValue(dispatch) {
                await session.callRustOperation(operationID: operation, callID: callID, name: name, argumentsJSON: arguments)
            }
        }
    }
}
