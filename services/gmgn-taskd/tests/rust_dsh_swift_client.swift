import Foundation

actor DSHText { var value = ""; func add(_ s: String) { value += s }; func check() { precondition(value == "hello" || value == "hello world") } }
@main struct DSHTest {
    static func main() async throws {
        let http = CLIHTTP(URL(string: CommandLine.arguments[1])!)
        let scenario = CommandLine.arguments[2]
        let client = RustDSHSessionClient(call: http.call)
        let id = RustDSHSessionClient.Identity(worldID: "w", residentScope: "s", hostSessionID: "h", runID: "r", eventID: "e")
        let sink = DSHText()
        let callbacks = RustDSHSessionClient.Callbacks(authorize: { tool in
            precondition(tool.phase == "authorize" && tool.operationID == nil)
            if scenario == "cancel" { try await client.cancel() }
            return "business-op"
        }, execute: { tool in
            precondition(tool.phase == "execute" && tool.operationID == "business-op")
            return .init(identity: id, acpSessionID: scenario == "wrongreceipt" ? "other" : tool.acpSessionID,
                         callID: tool.callID, operationID: "business-op", status: "completed", output: Data("{\"ok\":true}".utf8),
                         images: scenario == "images" ? [.init(bytes: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZAAAAABJRU5ErkJggg==")!, mediaType: "image/png")] : [])
        }, textDelta: { await sink.add($0) }, state: { _ in })
        let config = RustDSHSessionClient.Configuration(executable: "/fixture/node", entryPoint: "/fixture/runtime.mjs", compositionFile: "/fixture/config.yml",
            root: "/fixture", cwd: "/fixture/work", attachmentHome: "/fixture/home", persistenceRoot: "/fixture/sessions",
            persona: "resident", hostToolsPlugin: "/fixture/gmgn-host-tools.mjs", arguments: ["/fixture/runtime.mjs", "--config", "/fixture/config.yml"],
            environment: ["LANG": "C"], grantToken: "00000000-0000-4000-8000-000000000001", allowSilentCompletion: false)
        do {
            let result = try await client.run(identity: id, configuration: config, input: "test", images: [], tools: [.init(name: "move", description: "move", effect: "write", inputSchema: Data("{\"type\":\"object\"}".utf8))], callbacks: callbacks)
            precondition(["normal", "cancel", "images"].contains(scenario))
            precondition(result.state == (scenario == "cancel" ? "cancelled" : "completed"))
        } catch RustDSHSessionClient.ClientError.identityMismatch {
            precondition(["wrongreceipt", "wrongsession", "wrongtoken"].contains(scenario))
        } catch RustDSHSessionClient.ClientError.unknownExecution {
            precondition(scenario == "unknown")
            do { _ = try await client.run(identity: id, configuration: config, input: "test", images: [], tools: [], callbacks: callbacks); preconditionFailure("replay") }
            catch RustDSHSessionClient.ClientError.busy { }
        }
        if scenario != "wrongtoken" { await sink.check() }
        print("PASS DSH \(scenario)")
    }
}
