import Foundation

@main struct ClaudeAdapterTest {
    @MainActor static func main() async throws {
        let http = CLIHTTP(URL(string: CommandLine.arguments[1])!)
        let scenario = CommandLine.arguments[2]
        let service = AgentConversationService()
        let binding = RustResidentClaudeToolBinding(identity: .init(worldID: "w", residentScope: "s", hostSessionID: "h", runID: "r", eventID: "e"),
            transport: http.call, endpointURL: URL(string: CommandLine.arguments[1] + "/rpc")!,
            adapterExecutableURL: URL(fileURLWithPath: "/usr/bin/true"), environment: ["ANTHROPIC_API_KEY": "fixture-only-not-a-key"],
            effects: scenario == "wrongeffects" ? [:] : ["move": "write"], authorize: { tool in
                precondition(tool.phase == "authorize")
                if scenario == "cancel" { try await service.currentRustClaudeClient?.cancel() }
                return "business-op"
            })
        var calls = 0
        var tools = ResidentConversationTools(worldID: "w", schemasJSON: Data("[{\"name\":\"move\",\"description\":\"move\",\"inputSchema\":{\"type\":\"object\"}}]".utf8), call: { _, _, _ in
            calls += 1
            if scenario=="hostunknown" { return ResidentCodexToolReply(resultJSON:Data(#"{"ok":false,"code":"world_prop_execution_unknown"}"#.utf8),isError:true) }
            return ResidentCodexToolReply(resultJSON: Data("{\"ok\":true}".utf8), isError: false,
                image: .init(pngData: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZAAAAABJRU5ErkJggg==")!))
        }, cancel: {})
        if scenario != "bindingmissing" { tools.rustClaudeBinding = binding }
        do {
            let result = try await service.testSend(tools: tools)
            precondition(scenario == "adapter" && result.reply == "hello world" && result.sessionID == nil && calls == 1)
        } catch RustResidentClaudeClient.ClientError.invalidProtocol {
            precondition(scenario == "bindingmissing" || scenario == "wrongeffects")
            precondition(service.lastResidentFailure["code"] as? String == (scenario == "bindingmissing" ? "rust_claude_binding_missing" : "rust_claude_failed"))
        } catch RustResidentClaudeClient.ClientError.unknownExecution {
            precondition((scenario == "unknown" || scenario=="hostunknown") && service.lastResidentFailure["code"] as? String == "rust_claude_execution_unknown" && calls == (scenario=="hostunknown" ? 1 : 0))
        } catch is CancellationError {
            precondition(scenario == "cancel" && calls == 0 && service.lastResidentFailure["code"] as? String == "rust_claude_cancelled")
        }
        print("PASS Claude adapter \(scenario)")
    }
}
