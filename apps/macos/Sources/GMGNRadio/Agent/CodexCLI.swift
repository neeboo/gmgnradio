import Foundation

struct CodexCommandResult: Equatable, Sendable {
    let exitCode: Int32
    let output: String
}

protocol CodexCommandRunning: Sendable {
    func run(
        arguments: [String],
        standardInput: String?
    ) async throws -> CodexCommandResult
}

enum CodexCLIError: Error, LocalizedError {
    case unavailable
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "未找到 Codex CLI，请先安装 Codex。"
        case let .commandFailed(message):
            message.isEmpty ? "Codex 操作失败。" : message
        }
    }
}

struct CodexProcessRunner: CodexCommandRunning {
    let executableURL: URL

    func run(
        arguments: [String],
        standardInput: String? = nil
    ) async throws -> CodexCommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            let inputPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = Self.commandEnvironment(
                base: ProcessInfo.processInfo.environment
            )
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            process.standardInput = inputPipe

            try process.run()
            if let standardInput {
                inputPipe.fileHandleForWriting.write(Data(standardInput.utf8))
            }
            try? inputPipe.fileHandleForWriting.close()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CodexCommandResult(
                exitCode: process.terminationStatus,
                output: String(decoding: outputData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }.value
    }

    private static func commandEnvironment(
        base: [String: String]
    ) -> [String: String] {
        var environment = base
        let requiredDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let existingDirectories = (base["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        environment["PATH"] = (requiredDirectories + existingDirectories)
            .reduce(into: [String]()) { result, directory in
                if !result.contains(directory) {
                    result.append(directory)
                }
            }
            .joined(separator: ":")
        return environment
    }

    static func locate(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let pathCandidates = [
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
        if let match = pathCandidates.first(where: {
            fileManager.isExecutableFile(atPath: $0)
        }) {
            return URL(filePath: match)
        }

        let path = environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(filePath: String(directory))
                .appending(path: "codex")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
