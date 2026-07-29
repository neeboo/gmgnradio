import Foundation

protocol CodexPlanningExecuting: Sendable {
    func execute(prompt: String) async throws -> String
}

struct CodexCLIPlanningExecutor: CodexPlanningExecuting {
    private let runner: any CodexCommandRunning

    init(runner: any CodexCommandRunning) {
        self.runner = runner
    }

    static func live() throws -> CodexCLIPlanningExecutor {
        guard let executableURL = CodexProcessRunner.locate() else {
            throw CodexCLIError.unavailable
        }
        return CodexCLIPlanningExecutor(
            runner: CodexProcessRunner(executableURL: executableURL)
        )
    }

    func execute(prompt: String) async throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gmgn-radio-codex-\(UUID().uuidString)")
        let schemaURL = directory.appending(path: "show-proposal.schema.json")
        let outputURL = directory.appending(path: "show-proposal.json")

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.outputSchema.write(
            to: schemaURL,
            options: .atomic
        )

        let result = try await runner.run(
            arguments: [
                "exec",
                "--ephemeral",
                "--ignore-user-config",
                "--ignore-rules",
                "--sandbox", "read-only",
                "--skip-git-repo-check",
                "--color", "never",
                "--output-schema", schemaURL.path,
                "--output-last-message", outputURL.path,
                "-C", directory.path,
                "-",
            ],
            standardInput: prompt
        )
        guard result.exitCode == 0 else {
            throw CodexCLIError.commandFailed(result.output)
        }
        return try String(
            contentsOf: outputURL,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let outputSchema = Data(
        """
        {
          "type": "object",
          "properties": {
            "title": { "type": "string" },
            "direction": { "type": "string" },
            "slots": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "track_id": { "type": "string" },
                  "selection_reason": { "type": "string" },
                  "should_talk_before": { "type": "boolean" },
                  "transition_intent": { "type": "string" },
                  "visual": {
                    "type": "object",
                    "properties": {
                      "mood": { "type": "string" },
                      "palette": { "type": "string" },
                      "motion": { "type": "string" },
                      "intensity": { "type": "number" }
                    },
                    "required": [
                      "mood",
                      "palette",
                      "motion",
                      "intensity"
                    ],
                    "additionalProperties": false
                  }
                },
                "required": [
                  "track_id",
                  "selection_reason",
                  "should_talk_before",
                  "transition_intent",
                  "visual"
                ],
                "additionalProperties": false
              },
              "minItems": 5,
              "maxItems": 8
            }
          },
          "required": ["title", "direction", "slots"],
          "additionalProperties": false
        }
        """.utf8
    )
}
