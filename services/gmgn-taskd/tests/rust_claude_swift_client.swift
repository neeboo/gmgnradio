import Foundation

actor ClaudeText { var value = ""; func add(_ s: String) { value += s }; func check() { precondition(value == "hello" || value == "hello world") } }
@main struct ClaudeTest {
    static func main() async throws {
        let http = CLIHTTP(URL(string: CommandLine.arguments[1])!)
        let scenario = CommandLine.arguments[2]
        let client = RustResidentClaudeClient(call: http.call)
        let id = RustResidentClaudeClient.Identity(worldID: "w", residentScope: "s", hostSessionID: "h", runID: "r", eventID: "e")
        let sink = ClaudeText()
        let callbacks = RustResidentClaudeClient.Callbacks(authorize: { tool in
            precondition(tool.phase == "authorize" && tool.operationID == nil)
            if scenario == "cancel" { try await client.cancel() }
            return "business-op"
        }, execute: { tool in
            precondition(tool.phase == "execute" && tool.operationID == "business-op")
            return .init(identity: id, round: scenario == "wrongreceipt" ? "other" : tool.round,
                         callID: tool.callID, operationID: "business-op", status: "completed", output: Data("{\"ok\":true}".utf8),
                         images: scenario == "images" ? [.init(bytes: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZAAAAABJRU5ErkJggg==")!, mediaType: "image/png")] : [])
        }, textDelta: { await sink.add($0) }, state: { _ in })
        let config = RustResidentClaudeClient.Configuration(executable: "/fixture/claude",
            adapterExecutable: "/fixture/gmgn-mcpd", hostEndpoint: CommandLine.arguments[1] + "/rpc",
            environment: ["ANTHROPIC_API_KEY": "fixture-only-not-a-key"], allowSilentCompletion: false)
        do {
            let result = try await client.run(identity: id, configuration: config, input: "test", tools: [.init(name: "move", description: "move", effect: "write", inputSchema: Data("{\"type\":\"object\"}".utf8))], callbacks: callbacks)
            precondition(["normal", "cancel", "images"].contains(scenario))
            precondition(result.state == (scenario == "cancel" ? "cancelled" : "completed"))
        } catch RustResidentClaudeClient.ClientError.identityMismatch {
            precondition(["wrongreceipt", "wronground"].contains(scenario))
        } catch RustResidentClaudeClient.ClientError.invalidProtocol {
            precondition(scenario == "wrongstart")
        } catch RustResidentClaudeClient.ClientError.unknownExecution {
            precondition(scenario == "unknown")
            do { _ = try await client.run(identity: id, configuration: config, input: "test", tools: [], callbacks: callbacks); preconditionFailure("replay") }
            catch RustResidentClaudeClient.ClientError.busy { }
        }
        if scenario != "wrongstart" { await sink.check() }
        print("PASS Claude \(scenario)")
    }
}

