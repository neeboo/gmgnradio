import Foundation

enum CodexAccountState: Equatable, Sendable {
    case unavailable
    case signedOut
    case signedIn(method: String)
}

@MainActor
protocol CodexAccountServicing: AnyObject {
    func status() async -> CodexAccountState
    func login() async throws
}

@MainActor
final class CodexAgentAccountService: CodexAccountServicing {
    private let runner: (any CodexCommandRunning)?

    init(runner: (any CodexCommandRunning)? = CodexAgentAccountService.liveRunner()) {
        self.runner = runner
    }

    func status() async -> CodexAccountState {
        guard let runner else {
            return .unavailable
        }
        guard let result = try? await runner.run(
            arguments: ["login", "status"],
            standardInput: nil
        ) else {
            return .unavailable
        }
        guard result.exitCode == 0 else {
            return .signedOut
        }

        let output = result.output.lowercased()
        if output.contains("chatgpt") {
            return .signedIn(method: "ChatGPT")
        }
        if output.contains("api key") {
            return .signedIn(method: "API Key")
        }
        if output.contains("access token") {
            return .signedIn(method: "Access Token")
        }
        return .signedIn(method: "Codex")
    }

    func login() async throws {
        guard let runner else {
            throw CodexCLIError.unavailable
        }
        let result = try await runner.run(
            arguments: ["login"],
            standardInput: nil
        )
        guard result.exitCode == 0 else {
            throw CodexCLIError.commandFailed(result.output)
        }
    }

    private static func liveRunner() -> (any CodexCommandRunning)? {
        CodexProcessRunner.locate().map(CodexProcessRunner.init(executableURL:))
    }
}
