import Foundation
import Darwin

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
    /// 关联值是**仅供诊断**的原始 CLI 输出，可能含路径或凭据；绝不直接显示给用户。
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "没找到 Codex，请先安装。"
        case .commandFailed:
            "这次没能完成，请重新发送。"
                + "若反复出现，请在设置里重新登录 Codex。"
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

    fileprivate static func commandEnvironment(
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

enum DSHReplyTimeout: Error, LocalizedError {
    case request, turn

    var errorDescription: String? {
        switch self {
        case .request: "等回复等太久了，已经停下。请重新发送。"
        case .turn: "这轮等太久了，已经停下。请重新发送。"
        }
    }
}

/// Only the DSH headless lane uses this runner. Other CLI backends retain their
/// existing process behavior. Every invocation owns a fresh process and lease.
struct DSHProcessRunner: CodexCommandRunning {
    let executableURL: URL
    var requestTimeout: TimeInterval = 120

    func run(arguments: [String], standardInput: String?) async throws -> CodexCommandResult {
        let operation = DSHProcessOperation()
        return try await operation.run(executableURL: executableURL, arguments: arguments,
                                       standardInput: standardInput, timeout: requestTimeout)
    }
}

@MainActor private final class DSHProcessOperation {
    private var continuation: CheckedContinuation<CodexCommandResult, Error>?
    private var process: Process?
    private var deadline: Task<Void, Never>?
    private var settled = false
    private var stdoutResult: CodexCommandResult?
    private var stderrText: String?

    nonisolated init() {}

    func run(executableURL: URL, arguments: [String], standardInput: String?,
             timeout: TimeInterval) async throws -> CodexCommandResult {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Cancellation may win between the initial check and waiter
                // registration. Never launch after that lease has settled.
                guard !settled, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let child = Process(), output = Pipe(), diagnostics = Pipe(), input = Pipe()
                child.executableURL = executableURL
                child.arguments = arguments
                child.environment = CodexProcessRunner.commandEnvironment(base: ProcessInfo.processInfo.environment)
                child.standardOutput = output
                child.standardError = diagnostics
                child.standardInput = input
                process = child
                do { try child.run() }
                catch { settle(.failure(error)); return }
                let seconds = timeout.isFinite ? max(0.01, min(timeout, 3_600)) : 120
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    self?.stop(DSHReplyTimeout.request)
                }
                // Neither a pipe read nor a blocked stdin write can block the
                // main actor, cancellation, or the caller's deadline.
                _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                DispatchQueue.global(qos: .userInitiated).async {
                    if let standardInput { try? input.fileHandleForWriting.write(contentsOf: Data(standardInput.utf8)) }
                    try? input.fileHandleForWriting.close()
                }
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let data = diagnostics.fileHandleForReading.readDataToEndOfFile()
                    try? diagnostics.fileHandleForReading.close()
                    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { @MainActor [weak self] in
                        self?.stderrText = text
                        self?.settleAfterDrain()
                    }
                }
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    child.waitUntilExit()
                    try? output.fileHandleForReading.close()
                    let result = CodexCommandResult(exitCode: child.terminationStatus,
                        output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                    Task { @MainActor [weak self] in
                        self?.stdoutResult = result
                        self?.settleAfterDrain()
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.stop(CancellationError()) }
        }
    }

    private func settleAfterDrain() {
        guard !settled, let stdoutResult, let stderrText else { return }
        // DSH reserves stdout for the model reply. Diagnostics can be emitted
        // on a successful run, so only failed exits consume stderr.
        let output = stdoutResult.exitCode == 0 || stderrText.isEmpty ? stdoutResult.output : stderrText
        settle(.success(CodexCommandResult(exitCode: stdoutResult.exitCode, output: output)))
    }

    private func stop(_ error: Error) {
        guard !settled else { return }
        let child = process
        settle(.failure(error))
        guard let child, child.isRunning else { return }
        child.terminate()
        // Retain only this owned Process, never a global PID lookup. A delayed
        // kill checks that the same Process is still running, so a later turn
        // or a recycled PID cannot inherit this cancellation.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }

    private func settle(_ result: Result<CodexCommandResult, Error>) {
        guard !settled else { return }
        settled = true
        deadline?.cancel(); deadline = nil
        process = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(with: result)
    }
}
