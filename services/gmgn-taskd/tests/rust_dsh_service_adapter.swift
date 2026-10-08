import Foundation

@main struct DSHAdapterTest {
    @MainActor static func main() async throws {
        let http = CLIHTTP(URL(string: CommandLine.arguments[1])!)
        let scenario = CommandLine.arguments[2]
        let entry = CommandLine.arguments[3]
        let service = AgentConversationService()
        let binding = RustResidentDSHToolBinding(identity: .init(worldID: "w", residentScope: "s", hostSessionID: "h", runID: "r", eventID: "e"),
            transport: http.call, endpointURL: URL(string: CommandLine.arguments[1] + "/rpc")!,
            environment: ["LANG": "C", "GMGN_DSH_ACP_ENTRY": entry], effects: ["move": "write"], authorize: { tool in
                precondition(tool.phase == "authorize"); return "business-op"
            })
        var calls = 0
        var tools = ResidentConversationTools(worldID: "w", schemasJSON: Data("[{\"name\":\"move\",\"description\":\"move\",\"inputSchema\":{\"type\":\"object\"}}]".utf8), call: { _, _, _ in
            calls += 1
            if scenario=="hostunknown" { return ResidentCodexToolReply(resultJSON:Data(#"{"ok":false,"code":"world_prop_execution_unknown"}"#.utf8),isError:true) }
            return ResidentCodexToolReply(resultJSON: Data("{\"ok\":true}".utf8), isError: false,
                image: .init(pngData: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZAAAAABJRU5ErkJggg==")!))
        }, cancel: {})
        if scenario != "bindingmissing" { tools.rustDSHBinding = binding }
        do {
            let reply = try await service.testSend(scope: "s", tools: tools)
            precondition(scenario == "adapter" && reply == "hello world" && calls == 1)
        } catch RustDSHSessionClient.ClientError.invalidProtocol {
            precondition(scenario == "bindingmissing" && service.lastResidentFailure["code"] as? String == "rust_dsh_binding_missing")
        } catch RustDSHSessionClient.ClientError.unknownExecution {
            precondition(scenario=="hostunknown" && calls==1 && service.lastResidentFailure["code"] as? String=="rust_dsh_execution_unknown")
        }
        print("PASS DSH adapter \(scenario)")
    }
}
