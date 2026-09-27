//
//  ResidentClaudeProcessRunner.swift
//  GMGNRadio
//
//  Claude Code 专用进程 runner 与运行环境白名单。
//
//  为什么必须与通用 Codex/DSH runner 分离：
//   · Claude Code 需要显式、可审计的子进程 environment 与 working directory；
//     通用 CodexProcessRunner 取 `ProcessInfo.processInfo.environment` 全量环境并
//     继承调用方 cwd，既不隔离注入变量，也不能保证私有工作目录。
//   · Claude Code 需要自己的超时/取消语义：直接 Task 取消、service.cancel、
//     超时都必须终止并回收**本 runner 拥有的 Process**（先 TERM，再有界 KILL），
//     绝不按 PID 全局查找、绝不误杀其他进程。
//   · stdout/stderr 都必须有上界（本机模型输出可能很大）；**任一管道超量都立即
//     终止本进程并抛固定 `.outputTooLarge`**，绝不静默截断、绝不等到总超时；
//     读取缓冲始终以 `maximumOutputBytes` 为界。stderr 只用于排空管道，
//     绝不进入返回值或错误文案，避免把凭据/原始诊断回显出去。
//   · stdin prompt 可能远大于管道容量，且 CLI 派生的后代可能继承 stdin 读端却
//     不读：绝不用整段阻塞 `FileHandle.write`，改为自有非阻塞 poll 循环 +
//     线程安全取消；停止（cancel/timeout/超量）与直接子进程退出都通知 writer
//     有界退出，**只由 writer 自己关闭自有写端**，绝不遗留后台线程与管道 fd，
//     成功路径仍整段送完并按 EOF 关闭，正常早退（EPIPE）同样闭管。
//
//  安全面：本文件不读 Keychain、不读用户 Claude 配置、不登录、不写日志、不落盘。
//  只 import Foundation/Darwin，可被 tools/* 离线 swiftc 与 Service 一起编译。
//

import Foundation
import Darwin

// MARK: - Errors

/// Claude 子进程失败原因。全部映射到固定中文可见文案，绝不携带原始 stderr 或凭据。
enum ResidentClaudeProcessError: Error, LocalizedError, Equatable {
    case missingCredential
    case timedOut
    case launchFailed
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            "当前应用缺少 Claude Code 凭证（ANTHROPIC_API_KEY），请先在启动环境里配置后再重试。"
                + "终端临时设置的密钥不会自动传入桌面应用。"
        case .timedOut:
            "Claude Code 本次回复超时，已停止并回收进程。部分操作可能已经发生，请先核对当前状态。"
        case .launchFailed:
            "Claude Code 启动失败，请检查安装后重试。"
        case .outputTooLarge:
            "Claude Code 输出超出安全上限，已停止并回收进程。"
        }
    }
}

// MARK: - Environment whitelist

/// Claude 子进程环境白名单构造。
///
/// 只保留必要变量的**原值**（PATH/TMPDIR/HOME 等，不改 HOME）+ 显式取自当前进程
/// 的 `ANTHROPIC_API_KEY`（trim 后非空）+ 自建的私有 `CLAUDE_CONFIG_DIR`。
/// 因为只从白名单取值，`NODE_OPTIONS`/`NODE_PATH`/其他 `CLAUDE_CODE_*` 等注入变量
/// 天然被剔除；任何用户 Claude 配置或凭据存储都不会被读取或复制。
public enum ResidentClaudeEnvironment {
    public static let credentialKey = "ANTHROPIC_API_KEY"
    public static let configDirectoryKey = "CLAUDE_CONFIG_DIR"

    /// 只透传这些键的**原值**；不含 NODE_OPTIONS/NODE_PATH/其他 CLAUDE_CODE_*。
    public static let passthroughKeys: [String] = [
        "PATH", "TMPDIR", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL",
    ]

    /// 构造子进程环境；`nil` 表示缺少可用凭证（调用方必须在 spawn 前给出固定错误）。
    public static func make(
        base: [String: String],
        configDirectory: URL
    ) -> [String: String]? {
        guard let credential = base[credentialKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !credential.isEmpty else {
            return nil
        }
        var environment: [String: String] = [:]
        for key in passthroughKeys {
            if let value = base[key], !value.isEmpty {
                environment[key] = value
            }
        }
        environment[credentialKey] = credential
        environment[configDirectoryKey] = configDirectory.path
        return environment
    }
}

// MARK: - Runner

/// Claude Code 专用的一次性进程执行器：每个实例携带显式 environment、
/// workingDirectory 与 timeout，绝不复用通用 runner 的默认行为。
struct ResidentClaudeProcessRunner: CodexCommandRunning {
    let executableURL: URL
    let environment: [String: String]
    let workingDirectoryURL: URL
    var timeout: TimeInterval
    var maximumOutputBytes: Int

    init(
        executableURL: URL,
        environment: [String: String],
        workingDirectoryURL: URL,
        timeout: TimeInterval = 300,
        maximumOutputBytes: Int = 4_194_304
    ) {
        self.executableURL = executableURL
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.timeout = timeout.isFinite ? max(0.01, min(timeout, 3_600)) : 300
        self.maximumOutputBytes = max(1_024, maximumOutputBytes)
    }

    func run(
        arguments: [String],
        standardInput: String?
    ) async throws -> CodexCommandResult {
        let operation = ResidentClaudeProcessOperation(
            executableURL: executableURL,
            environment: environment,
            workingDirectoryURL: workingDirectoryURL,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )
        return try await operation.run(arguments: arguments, standardInput: standardInput)
    }
}

// MARK: - One owned process operation

/// @MainActor 上登记 continuation/deadline/owned Process；字节搬运与排空在后台队列，
/// 绝不让管道读写或阻塞的 stdin 写入卡住主线程、取消或调用方 deadline。
///
/// 结算顺序（P2-2）：任何失败都先**记录错误并立即 TERM**，250ms 后若同一个自有
/// Process 仍活着才 KILL；只有在 `waitUntilExit()` 真正 reap 了直接子进程之后才
/// resume continuation。因此调用方拿到错误返回时 `kill(pid, 0)` 必然失败，
/// 不存在“已 settle、进程却还在跑/未回收”的窗口。
///
/// stdin 自有写端由独立的有界 writer 持有：结算额外等待 writer 结束（写完关闭 /
/// 有界取消关闭），保证返回时既没有遗留阻塞线程，也没有仍开着的自有写端 fd。
@MainActor
private final class ResidentClaudeProcessOperation {
    private let executableURL: URL
    private let environment: [String: String]
    private let workingDirectoryURL: URL
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int

    private var continuation: CheckedContinuation<CodexCommandResult, Error>?
    private var process: Process?
    private var deadline: Task<Void, Never>?
    private var escalation: Task<Void, Never>?
    private var settled = false
    /// 是否真正 spawn 过子进程；未 spawn（launch 失败前取消等）绝不等待 reader。
    private var didSpawn = false
    /// 直接子进程已退出且被**独立**的 `waitUntilExit()` reap（不与读端 EOF 排队）。
    private var exitObserved = false
    /// 直接子进程退出码（`exitObserved` 后有效）。
    private var terminationStatus: Int32 = 0
    /// stdout reader 已结束（读到 EOF / 被停止取消）。
    private var stdoutReaderFinished = false
    /// stderr reader 已结束（读到 EOF / 被停止取消）。
    private var stderrReaderFinished = false
    /// stdin writer 已结束（整段写完 / 被停止取消 / 读端全关 EPIPE），且自有写端已关闭。
    private var writerFinished = false
    /// stdout 是否超量（数据已丢弃，绝不回显）。
    private var stdoutOverflowed = false
    /// stderr 是否超量（数据已丢弃，绝不回显）。
    private var stderrOverflowed = false
    /// 正常 stdout 原始字节；超量/取消时为 nil。
    private var stdoutData: Data?
    /// 自有读端。停止时置位线程安全取消标识，使读取循环有界退出。
    private var stdoutReader: ResidentClaudeBoundedPipeReader?
    private var stderrReader: ResidentClaudeBoundedPipeReader?
    /// 自有 stdin 写端。停止/直接子进程退出时置位线程安全取消标识，使写循环有界退出；
    /// 关闭自有写端只发生在 writer 自己的线程体内。
    private var inputWriter: ResidentClaudeBoundedPipeWriter?
    /// 第一个失败原因（超时/取消/超量）；一旦记录，结算一定以失败收场。
    private var pendingError: Error?

    nonisolated init(
        executableURL: URL,
        environment: [String: String],
        workingDirectoryURL: URL,
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) {
        self.executableURL = executableURL
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }

    func run(arguments: [String], standardInput: String?) async throws -> CodexCommandResult {
        try Task.checkCancellation()
        let executableURL = self.executableURL
        let environment = self.environment
        let workingDirectoryURL = self.workingDirectoryURL
        let timeout = self.timeout
        let maximumOutputBytes = self.maximumOutputBytes
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // 取消可能在上一次检查与 waiter 登记之间获胜：绝不在这之后启动进程。
                guard !settled, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let child = Process(), output = Pipe(), diagnostics = Pipe(), input = Pipe()
                child.executableURL = executableURL
                child.arguments = arguments
                child.environment = environment
                child.currentDirectoryURL = workingDirectoryURL
                child.standardOutput = output
                child.standardError = diagnostics
                child.standardInput = input
                process = child
                do {
                    try child.run()
                } catch {
                    // 未启动任何子进程：无需回收，直接结算。
                    settle(.failure(ResidentClaudeProcessError.launchFailed))
                    return
                }
                didSpawn = true
                let stdoutReader = ResidentClaudeBoundedPipeReader(
                    fileDescriptor: output.fileHandleForReading.fileDescriptor,
                    limit: maximumOutputBytes,
                    onOverflow: { [weak self] in
                        Task { @MainActor in self?.stop(ResidentClaudeProcessError.outputTooLarge) }
                    }
                )
                let stderrReader = ResidentClaudeBoundedPipeReader(
                    fileDescriptor: diagnostics.fileHandleForReading.fileDescriptor,
                    limit: maximumOutputBytes,
                    onOverflow: { [weak self] in
                        Task { @MainActor in self?.stop(ResidentClaudeProcessError.outputTooLarge) }
                    }
                )
                self.stdoutReader = stdoutReader
                self.stderrReader = stderrReader
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    self?.stop(ResidentClaudeProcessError.timedOut)
                }
                // stdin 自有写端：不整段阻塞 write。writer 在有界 poll 循环里送字节，
                // 停止（cancel/timeout/超量）或直接子进程退出都会让它有界返回；**只有
                // writer 自己**在结束后关闭自有写端，绝不遗留线程或仍开着的 fd。
                let inputWriter = ResidentClaudeBoundedPipeWriter(
                    fileDescriptor: input.fileHandleForWriting.fileDescriptor,
                    data: Data((standardInput ?? "").utf8)
                )
                self.inputWriter = inputWriter
                _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = inputWriter.writeToEnd()
                    try? input.fileHandleForWriting.close()
                    Task { @MainActor [weak self] in
                        self?.writerFinished = true
                        self?.settleAfterReaders()
                    }
                }
                // 直接子进程的回收**独立于两个读端**：即使 CLI 派生的后代仍持有
                // stdout/stderr 写端、EOF 永不到达，`waitUntilExit()` 也一定在此线程
                // 上 reap 直接子进程，绝不与 stdout 排空排队。
                DispatchQueue.global(qos: .userInitiated).async {
                    child.waitUntilExit()
                    let status = child.terminationStatus
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.terminationStatus = status
                        self.exitObserved = true
                        // 直接子进程已退出：剩余 stdin 不再有必需消费者。正常整段送完
                        // 路径此时 writer 早已写完并关闭写端，取消是无害空操作；阻塞在
                        // 管道上的 writer（后代继承读端却不读）则在此有界退出并闭管，
                        // 绝不拖到总超时，也绝不等后代释放读端。
                        self.inputWriter?.cancel()
                        self.settleAfterReaders()
                    }
                }
                // stderr 只排空、绝不入返回值/错误；超量同样立即终止（onOverflow 只
                // 用于尽早 TERM，最终判定以 reader 返回的 overflow 结果为准）。读端在
                // 停止后由读线程有界退出并只关闭本 runner 自己的读端。
                DispatchQueue.global(qos: .userInitiated).async {
                    let outcome = stderrReader.readToEnd()
                    try? diagnostics.fileHandleForReading.close()
                    Task { @MainActor [weak self] in
                        self?.stderrOverflowed = outcome.overflowed
                        self?.stderrReaderFinished = true
                        self?.settleAfterReaders()
                    }
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    // 超量时返回 nil 并丢弃已读字节；仍持续排空直到 EOF/停止，避免
                    // 子进程因管道写满阻塞，同时内存始终有界。
                    let outcome = stdoutReader.readToEnd()
                    try? output.fileHandleForReading.close()
                    Task { @MainActor [weak self] in
                        self?.stdoutOverflowed = outcome.overflowed
                        self?.stdoutData = outcome.data
                        self?.stdoutReaderFinished = true
                        self?.settleAfterReaders()
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.stop(CancellationError()) }
        }
    }

    /// 只有直接子进程已退出并被 reap、**stdout/stderr 两个读端都已结束、且 stdin
    /// writer 也已结束**（整段写完关闭 / 有界取消关闭自有写端）后才结算。
    /// 成功路径要求两个读端都自然读到 EOF（完整收敛 stdout 与 stderr）、writer 整段
    /// 送完；停止路径的读端与 writer 由取消标识有界退出。任一读端 overflow 一律固定
    /// `.outputTooLarge`（不依赖可能晚到的 onOverflow 回调顺序），其余失败原因
    /// （超时/取消）随之结算。
    private func settleAfterReaders() {
        guard !settled, exitObserved, stdoutReaderFinished, stderrReaderFinished, writerFinished else { return }
        if stdoutOverflowed || stderrOverflowed {
            settle(.failure(ResidentClaudeProcessError.outputTooLarge))
        } else if let pendingError {
            settle(.failure(pendingError))
        } else if let stdoutData {
            settle(.success(CodexCommandResult(
                exitCode: terminationStatus,
                output: String(decoding: stdoutData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )))
        } else {
            settle(.failure(ResidentClaudeProcessError.outputTooLarge))
        }
    }

    /// 记录失败原因并终止**本次拥有的** Process：先 TERM，250ms 后若同一个 Process
    /// 仍活着才 KILL。只检查同一个 Process 对象是否仍在运行，绝不按 PID 全局查找；
    /// KILL 前 `child.isRunning` 复核保证迟到的 KILL 不会命中被复用的 PID。
    /// 同时置位两个自有读端与自有 stdin writer 的线程安全取消标识：即使 CLI 派生的
    /// 后代仍持有 stdout/stderr 写端或 stdin 读端、EOF 永不到达、输入大于管道容量，
    /// 读取/写入循环也会在轮询窗口内有界退出，绝不等待后代释放管道。停止只关闭本
    /// runner 自己的读端与写端（分别由读线程/写线程负责），绝不杀进程树、不碰未知
    /// PID。这里**不结算**：等直接子进程被独立 reap 且两个读端与 writer 结束后统一结算。
    private func stop(_ error: Error) {
        guard !settled else { return }
        if pendingError == nil { pendingError = error }
        deadline?.cancel()
        deadline = nil
        stdoutReader?.cancel()
        stderrReader?.cancel()
        inputWriter?.cancel()
        // 未 spawn 任何子进程（launch 失败前的取消等）：没有 reader 可等，直接结算。
        guard didSpawn, let child = process else {
            settle(.failure(error))
            return
        }
        guard child.isRunning else { return }
        child.terminate()
        guard escalation == nil else { return }
        escalation = Task { @MainActor [weak self, weak child] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !self.settled else { return }
            guard let child, self.process === child, child.isRunning else { return }
            kill(child.processIdentifier, SIGKILL)
        }
    }

    private func settle(_ result: Result<CodexCommandResult, Error>) {
        guard !settled else { return }
        settled = true
        deadline?.cancel()
        deadline = nil
        escalation?.cancel()
        escalation = nil
        process = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(with: result)
    }
}

// MARK: - Bounded, cancellable pipe writer

/// 自有 stdin 管道的**有界、可取消**写入器，运行在调用方提供的自有线程上。
///
/// 为什么不能直接用 `FileHandle.write(contentsOf:)` 整段写出：当 CLI 派生的后代
/// 继承 stdin 读端却不读时，只要 prompt 大于管道容量，阻塞 write 就会永远卡住后台
/// 线程；即使直接子进程已被终止并 reap，writer 线程与自有写端 fd 也永久遗留，后代更
/// 永远等不到 EOF。这里改为非阻塞 `write(2)` + `poll(2)` 循环，并暴露线程安全的
/// `cancel()`：停止或直接子进程退出时由 MainActor 置位取消标识，写循环在 50ms 轮询
/// 窗口内退出，**绝不等待后代释放读端**。
///
/// 只操作本 runner 自己的**写端**：关闭自有写端只发生在调用方 writer 线程体内
/// （本类型不自行关闭 fd），绝不按 PID 查找、绝不杀进程树、绝不关闭任何未知 fd。
private final class ResidentClaudeBoundedPipeWriter: @unchecked Sendable {
    /// 轮询窗口：取消标识置位后，写循环最多阻塞这么久即退出。
    private static let pollMilliseconds: Int32 = 50

    private let fileDescriptor: Int32
    private let data: Data

    private let lock = NSLock()
    private var cancelled = false

    nonisolated init(fileDescriptor: Int32, data: Data) {
        self.fileDescriptor = fileDescriptor
        self.data = data
    }

    /// 线程安全取消：置位后写循环在下一次写/轮询检查时**有界**退出。
    nonisolated func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// 非阻塞写 + poll 循环，始终有界返回。返回 `true` 表示整段输入已送出（正常成功
    /// 路径，随后由调用方关闭写端令对端读到 EOF）；返回 `false` 表示被取消、读端全部
    /// 关闭（EPIPE，正常早退）或写错误——无论哪种，调用方随后关闭自有写端。
    nonisolated func writeToEnd() -> Bool {
        let flags = fcntl(fileDescriptor, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
        var offset = 0
        var descriptor = pollfd(
            fd: fileDescriptor, events: Int16(POLLOUT), revents: 0
        )
        while true {
            if isCancelled { return false }
            while offset < data.count {
                let written = data.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return write(fileDescriptor, base.advanced(by: offset), data.count - offset)
                }
                if written > 0 {
                    offset += written
                } else if written == 0 {
                    break
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                } else {
                    // EPIPE / 写端错误：读端已全部关闭（直接子进程正常早退），
                    // 剩余输入不再有消费者，有界退出并由调用方闭管。
                    return false
                }
                if isCancelled { return false }
            }
            if offset >= data.count { return true }
            if isCancelled { return false }
            descriptor.revents = 0
            let ready = poll(&descriptor, 1, Self.pollMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                return false
            }
            // ready == 0（轮询窗口超时）时回到循环顶部复核取消标识/剩余字节。
        }
    }
}

// MARK: - Bounded, cancellable pipe reader

/// 自有管道的**有界、可取消**读取器，运行在调用方提供的自有线程上。
///
/// 为什么不能直接用 `FileHandle.read(upToCount:)` 读到 EOF：CLI 可能派生持有
/// stdout/stderr 写端的后代进程；即使直接子进程已被终止并 reap，只要后代还活着，
/// 读端就永远等不到 EOF，timeout/cancel 会因此无限挂起。这里改为非阻塞 `read(2)`
/// + `poll(2)` 循环，并暴露线程安全的 `cancel()`：停止时由 MainActor 置位取消标识，
/// 读取循环在 50ms 轮询窗口内退出，**绝不等待后代释放管道**。
///
/// 读取缓冲始终以 `limit` 为界：一旦超量立即丢弃已读数据并回调一次（调用方据此
/// 终止直接子进程），此后只继续排空不再累积——内存有界且绝不把超量内容带出。
/// 该类型只操作本 runner 自己的读端，绝不按 PID 查找、绝不杀进程树。
private final class ResidentClaudeBoundedPipeReader: @unchecked Sendable {
    struct Outcome: Sendable {
        /// 正常读取到的字节；`nil` 表示超量（已丢弃）或被取消。
        let data: Data?
        /// 是否检测到超量（数据已全部丢弃）。
        let overflowed: Bool
    }

    /// 轮询窗口：停止取消标识后，读取循环最多阻塞这么久即退出。
    private static let pollMilliseconds: Int32 = 50
    private static let chunkBytes = 65_536

    private let fileDescriptor: Int32
    private let limit: Int
    private let onOverflow: @Sendable () -> Void

    private let lock = NSLock()
    private var cancelled = false

    nonisolated init(
        fileDescriptor: Int32,
        limit: Int,
        onOverflow: @escaping @Sendable () -> Void
    ) {
        self.fileDescriptor = fileDescriptor
        self.limit = limit
        self.onOverflow = onOverflow
    }

    /// 线程安全取消：置位后读取循环在下一次轮询/读循环检查时**有界**退出。
    nonisolated func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// 读到 EOF / 取消 / 错误，始终有界返回。返回 `data == nil` 表示超量或取消。
    nonisolated func readToEnd() -> Outcome {
        let flags = fcntl(fileDescriptor, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Self.chunkBytes, alignment: MemoryLayout<UInt8>.alignment
        )
        defer { buffer.deallocate() }
        var accumulated = Data()
        var overflowed = false
        var descriptor = pollfd(
            fd: fileDescriptor, events: Int16(POLLIN), revents: 0
        )
        while true {
            if isCancelled {
                return Outcome(data: nil, overflowed: overflowed)
            }
            descriptor.revents = 0
            let ready = poll(&descriptor, 1, Self.pollMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                return Outcome(data: overflowed ? nil : accumulated, overflowed: overflowed)
            }
            if ready == 0 { continue }
            while true {
                let count = read(fileDescriptor, buffer, Self.chunkBytes)
                if count > 0 {
                    if !overflowed {
                        if accumulated.count + count > limit {
                            overflowed = true
                            accumulated = Data()
                            onOverflow()
                        } else {
                            accumulated.append(
                                buffer.assumingMemoryBound(to: UInt8.self), count: count
                            )
                        }
                    }
                } else if count == 0 {
                    return Outcome(data: overflowed ? nil : accumulated, overflowed: overflowed)
                } else {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    return Outcome(data: overflowed ? nil : accumulated, overflowed: overflowed)
                }
                if isCancelled {
                    return Outcome(data: nil, overflowed: overflowed)
                }
            }
        }
    }
}
