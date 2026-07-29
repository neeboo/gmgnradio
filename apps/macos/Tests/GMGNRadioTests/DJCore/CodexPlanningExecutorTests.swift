import Foundation
import Testing
@testable import GMGNRadio

@Test
func codexPlanningExecutorRequestsTheStructuredShowSchema() async throws {
    let runner = StructuredOutputCodexRunner()
    let executor = CodexCLIPlanningExecutor(runner: runner)

    let output = try await executor.execute(prompt: "排一档节目")

    #expect(output.contains(#""title":"测试节目""#))
    let schema = try #require(await runner.capturedSchema())
    #expect(schema.contains(#""title""#))
    #expect(schema.contains(#""direction""#))
    #expect(schema.contains(#""selection_reason""#))
    #expect(schema.contains(#""should_talk_before""#))
    #expect(schema.contains(#""transition_intent""#))
    #expect(schema.contains(#""visual""#))
    #expect(schema.contains(#""additionalProperties": false"#))
}

private actor StructuredOutputCodexRunner: CodexCommandRunning {
    private var schema: String?

    func run(
        arguments: [String],
        standardInput: String?
    ) async throws -> CodexCommandResult {
        let schemaIndex = try #require(arguments.firstIndex(of: "--output-schema"))
        let outputIndex = try #require(
            arguments.firstIndex(of: "--output-last-message")
        )
        let schemaURL = URL(filePath: arguments[schemaIndex + 1])
        let outputURL = URL(filePath: arguments[outputIndex + 1])
        schema = try String(contentsOf: schemaURL, encoding: .utf8)
        try Data(
            """
            {"title":"测试节目","direction":"测试方向","slots":[]}
            """.utf8
        ).write(to: outputURL)
        return CodexCommandResult(exitCode: 0, output: "")
    }

    func capturedSchema() -> String? {
        schema
    }
}
