import Foundation

@main struct AdapterTest {
    @MainActor static func main() async throws {
        let http = CLIHTTP(URL(string: CommandLine.arguments[1])!)
        let scenario = CommandLine.arguments[2]
        let id = RustCodexSessionClient.Identity(worldID: "w", residentScope: "s", hostSessionID: "h", runID: "r", eventID: "e")
        let service = AgentConversationService()
        for (json, error, status) in [
            (#"{"ok":false,"code":"world_prop_execution_unknown"}"#, true, "unknown"),
            (#"{"error":{"code":"world_prop_execution_unknown"}}"#, true, "unknown"),
            (#"{"error":"host_execution_unknown"}"#, true, "unknown"),
            (#"{"code":"rust_operation_result_unknown"}"#, true, "unknown"),
            (#"{"code":"world_prop_execution_unknown"}"#, false, "unknown"),
            (#"{"code":"world_prop_invalid_support","message":"unknown"}"#, true, "rejected"),
            (#"{"code":42,"error":{"message":"world_prop_execution_unknown"}}"#, true, "rejected"),
            (#"{"ok":true}"#, false, "completed")
        ] { precondition(AgentConversationService.rustHostReceiptStatus(resultJSON:Data(json.utf8),isError:error)==status) }
        let binding = RustResidentToolBinding(identity: id, transport: http.call, environment: ["LANG": "C"], effects: ["move": "write"], authorize: { tool in
            precondition(tool.phase == "authorize"); return "business-op"
        })
        var calls = 0
        var tools = ResidentConversationTools(worldID: "w", schemasJSON: Data("[{\"name\":\"move\",\"description\":\"move\",\"inputSchema\":{\"type\":\"object\"}}]".utf8), call: { _, name, _ in
            precondition(name == "move"); calls += 1
            if scenario.hasPrefix("hostunknown") {
                return ResidentCodexToolReply(resultJSON:Data(#"{"ok":false,"code":"world_prop_execution_unknown"}"#.utf8),isError:true,
                    image:scenario=="hostunknownbadimage" ? .init(pngData:Data()) : nil)
            }
            if scenario=="rejected" {return ResidentCodexToolReply(resultJSON:Data(#"{"ok":false,"code":"world_prop_invalid_support"}"#.utf8),isError:true)}
            return ResidentCodexToolReply(resultJSON: Data("{\"ok\":true}".utf8), isError: false,
                image: .init(pngData: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZAAAAABJRU5ErkJggg==")!))
        }, cancel: {})
        if scenario != "bindingmissing" { tools.rustBinding = binding }
        do {
            let result = try await service.testSend(executable: URL(fileURLWithPath: "/fixture/codex"), prompt: "test", imageURLs: [], sessionID: "thread", tools: tools)
            precondition((scenario == "adapter" || scenario=="rejected") && result.reply == "hello world" && result.sessionID == "thread" && calls == 1)
        } catch AgentConversationError.worldToolsUnavailable {
            precondition(scenario == "bindingmissing" && service.lastResidentFailure["code"] as? String == "rust_cli_binding_missing")
        } catch RustCodexSessionClient.ClientError.unknownExecution {
            precondition(scenario.hasPrefix("hostunknown") && calls==1 && service.lastResidentFailure["code"] as? String=="rust_cli_execution_unknown")
        }
        print("PASS adapter \(scenario)")
    }
}
