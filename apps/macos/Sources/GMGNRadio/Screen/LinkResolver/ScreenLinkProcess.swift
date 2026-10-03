import Foundation
import Synchronization

// MARK: - 受控子进程：**协议跨平台**，OS 适配在下面单独一层

/// 一次子进程调用的输入。
struct ScreenLinkProcessRequest: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
    /// **受控环境**：不带用户 PATH、不读用户配置目录、不继承代理变量。
    let environment: [String: String]
    let workingDirectory: String?
    let timeout: Duration
}

/// 一次子进程调用的输出。
struct ScreenLinkProcessResult: Equatable, Sendable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: String
    let timedOut: Bool
    let wasCancelled: Bool
    /// 进程**根本没起来**时的原因（`nil` = 起来过）。
    let launchFailure: String?
}

/// 跑一次受控子进程。macOS 侧是 `PosixScreenLinkProcessRunner`；Windows 侧将来有它自己的
/// 实现（同样的请求/回执形状）。判据用假实现。
protocol ScreenLinkProcessRunning: Sendable {
    func run(_ request: ScreenLinkProcessRequest) async -> ScreenLinkProcessResult
}

// MARK: - POSIX（macOS / Linux）适配

#if !os(Windows)

/// 用 `Foundation.Process` 跑一次 yt-dlp，并在**取消 / 超时**时终止它。
///
/// 关键点只有两个，都是"别让一次解析挂死整个界面"：
/// 1. 两个输出管道**在等待退出之前**就被并发排空 —— yt-dlp 的信息 JSON 有上百 KB，
///    超过管道缓冲，先等退出再读会死锁；
/// 2. 取消与超时都**终止子进程**（先 `terminate`，宽限后 `SIGKILL`），回执因此一定
///    会到；`stop()` / 换片 / 删电视时不会有解析器在后台继续跑。
final class PosixScreenLinkProcessRunner: ScreenLinkProcessRunning, @unchecked Sendable {
    /// 宽限期：`terminate()` 之后多久还没退就 `SIGKILL`。
    private let killGrace: Duration

    init(killGrace: Duration = .seconds(2)) {
        self.killGrace = killGrace
    }

    func run(_ request: ScreenLinkProcessRequest) async -> ScreenLinkProcessResult {
        let run = ProcessRun(request: request, killGrace: killGrace)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                run.start(continuation)
            }
        } onCancel: {
            run.cancel()
        }
    }
}

/// 一次运行的账。所有跨线程状态都在锁里，`Continuation` 恰好恢复一次。
private final class ProcessRun: @unchecked Sendable {
    private let lock = NSLock()
    private let request: ScreenLinkProcessRequest
    private let killGrace: Duration
    private var process: Process?
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutDone = false
    private var stderrDone = false
    private var exitObserved = false
    private var finished = false
    private var timedOut = false
    private var cancelled = false
    private var launchFailure: String?
    private var continuation: CheckedContinuation<ScreenLinkProcessResult, Never>?

    init(request: ScreenLinkProcessRequest, killGrace: Duration) {
        self.request = request
        self.killGrace = killGrace
    }

    func start(_ continuation: CheckedContinuation<ScreenLinkProcessResult, Never>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(returning: failureResult(cancelled: true, timedOut: false))
            return
        }
        self.continuation = continuation
        lock.unlock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executablePath)
        process.arguments = request.arguments
        process.environment = request.environment
        if let workingDirectory = request.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        lock.lock()
        self.process = process
        lock.unlock()

        process.terminationHandler = { [weak self] _ in
            self?.markExit()
        }
        do {
            try process.run()
        } catch {
            lock.lock()
            launchFailure = error.localizedDescription
            lock.unlock()
            markExit()
            return
        }

        // 先并发排空，再谈退出 —— 顺序反了会把上百 KB 的 JSON 卡在管道上。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
            self?.markRead(isStdout: true, data: data)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            self?.markRead(isStdout: false, data: data)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.seconds(request.timeout)
        ) { [weak self] in
            self?.expire()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        terminate(process)
    }

    private func expire() {
        lock.lock()
        guard !finished, !exitObserved else { lock.unlock(); return }
        timedOut = true
        let process = self.process
        lock.unlock()
        terminate(process)
    }

    private func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.seconds(killGrace)
        ) { [weak process] in
            guard let process, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func markRead(isStdout: Bool, data: Data) {
        lock.lock()
        if isStdout { stdout = data; stdoutDone = true } else { stderr = data; stderrDone = true }
        let ready = exitObserved && stdoutDone && stderrDone && !finished
        if ready { finished = true }
        let continuation = ready ? self.continuation : nil
        self.continuation = ready ? nil : self.continuation
        let result = ready ? snapshotLocked() : nil
        lock.unlock()
        if let continuation, let result { continuation.resume(returning: result) }
    }

    private func markExit() {
        lock.lock()
        exitObserved = true
        let ready = stdoutDone && stderrDone && !finished
        if ready { finished = true }
        let continuation = ready ? self.continuation : nil
        self.continuation = ready ? nil : self.continuation
        let result = ready ? snapshotLocked() : nil
        lock.unlock()
        if let continuation, let result { continuation.resume(returning: result) }
    }

    private func snapshotLocked() -> ScreenLinkProcessResult {
        ScreenLinkProcessResult(
            terminationStatus: process?.terminationStatus ?? -1,
            standardOutput: stdout,
            standardError: String(decoding: stderr, as: UTF8.self),
            timedOut: timedOut,
            wasCancelled: cancelled,
            launchFailure: launchFailure
        )
    }

    private func failureResult(cancelled: Bool, timedOut: Bool) -> ScreenLinkProcessResult {
        ScreenLinkProcessResult(
            terminationStatus: -1, standardOutput: Data(), standardError: "",
            timedOut: timedOut, wasCancelled: cancelled, launchFailure: nil
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// `FileHandle.readToEnd()` 是 macOS 10.15.4+ 才有的便利方法；这里用一个等价实现，
/// 免得在更老的 SDK 上编不过。
private extension FileHandle {
    func readToEnd() throws -> Data {
        var data = Data()
        while true {
            let chunk = try read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data
    }
}

#else

/// Windows 那一半**还没有**进程适配层。它存在是为了让"协议/请求/回执/取消/错误"这四样
/// 在 Windows 上照样只有一处定义：接上时只换这个类型，接口与错误形状一个字不动。
/// 现在如实报 `unsupportedPlatform`，不假装能跑。
final class WindowsScreenLinkProcessRunner: ScreenLinkProcessRunning, @unchecked Sendable {
    func run(_ request: ScreenLinkProcessRequest) async -> ScreenLinkProcessResult {
        ScreenLinkProcessResult(
            terminationStatus: -1, standardOutput: Data(), standardError: "",
            timedOut: false, wasCancelled: false, launchFailure: "unsupported_platform"
        )
    }
}

#endif

// MARK: - 判据用的假实现

/// 离屏判据用的假进程：**不启动任何东西**，把预先排好的结果按顺序吐出来。
///
/// 它存在是为了让"缺 helper / 超时 / 取消 / 非零退出 / JSON 坏掉"这些行为能被确定性地
/// 驱动，不依赖网络与真机。
final class FakeScreenLinkProcessRunner: ScreenLinkProcessRunning, @unchecked Sendable {
    private let state = Mutex<State>(State(results: [], requests: []))

    private struct State: Sendable {
        var results: [ScreenLinkProcessResult]
        var requests: [ScreenLinkProcessRequest]
    }

    init(results: [ScreenLinkProcessResult]) {
        state.withLock { $0.results = results }
    }

    convenience init(
        status: Int32 = 0, output: Data = Data(), error: String = "",
        timedOut: Bool = false, cancelled: Bool = false, launchFailure: String? = nil
    ) {
        self.init(results: [ScreenLinkProcessResult(
            terminationStatus: status, standardOutput: output, standardError: error,
            timedOut: timedOut, wasCancelled: cancelled, launchFailure: launchFailure
        )])
    }

    var requests: [ScreenLinkProcessRequest] { state.withLock { $0.requests } }

    func run(_ request: ScreenLinkProcessRequest) async -> ScreenLinkProcessResult {
        state.withLock { state in
            state.requests.append(request)
            if state.results.isEmpty {
                return ScreenLinkProcessResult(
                    terminationStatus: -1, standardOutput: Data(), standardError: "",
                    timedOut: false, wasCancelled: false, launchFailure: "no_scripted_result"
                )
            }
            return state.results.removeFirst()
        }
    }
}
