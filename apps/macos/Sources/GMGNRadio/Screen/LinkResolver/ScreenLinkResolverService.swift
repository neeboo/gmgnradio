import Foundation
import Synchronization

// MARK: - 解析编排：定位 → 受控子进程 → 解析输出（跨平台协议，macOS 适配在底层）

/// 把「用户给了一个公开网站链接」变成 `ScreenLinkResolution` 的**唯一**入口。
///
/// 它本身不含平台代码：定位、参数构造、输出解析都是纯值，真正跑进程的是
/// `ScreenLinkProcessRunning`。于是 macOS / Windows 各自只换那一层适配。
final class ScreenLinkResolverService: ScreenLinkResolving, ScreenLinkCancelling, @unchecked Sendable {
    private let locator: ScreenLinkHelperLocator
    private let runner: ScreenLinkProcessRunning
    private let javascriptRuntimeName: String?
    private let javascriptRuntimePath: String?
    private let workingDirectory: String?
    /// 当前在跑的那一个任务。`Mutex`（不是 `NSLock`）：`NSLock.lock()` 在 async 上下文里
    /// 是 Swift 6 的错误，而这里必须跨 `await` 持有它。
    private let currentTask = Mutex<Task<ScreenLinkResolution, Never>?>(nil)

    init(
        locator: ScreenLinkHelperLocator,
        runner: ScreenLinkProcessRunning,
        javascriptRuntimeName: String? = nil,
        javascriptRuntimePath: String? = nil,
        workingDirectory: String? = nil
    ) {
        self.locator = locator
        self.runner = runner
        self.javascriptRuntimeName = javascriptRuntimeName
        self.javascriptRuntimePath = javascriptRuntimePath
        self.workingDirectory = workingDirectory
    }

    /// 便利构造：按平台选进程适配层。**生产**里 `allowDevOverride` 为 `false`。
    static func live(
        bundleHelpersDirectory: String? = ScreenLinkHelperLocator.defaultBundleHelpersDirectory(),
        managedHelpersDirectory: String? = ScreenLinkHelperLocator.defaultManagedHelpersDirectory(),
        allowDevOverride: Bool,
        javascriptRuntimeName: String? = nil,
        javascriptRuntimePath: String? = nil
    ) -> ScreenLinkResolverService {
        let locator = ScreenLinkHelperLocator(
            bundleHelpersDirectory: bundleHelpersDirectory,
            managedHelpersDirectory: managedHelpersDirectory,
            devOverridePath: allowDevOverride
                ? ScreenLinkHelperLocator.devOverridePath() : nil,
            allowDevOverride: allowDevOverride
        )
        // Only a hash-verified bundled/managed runtime may be discovered automatically.
        // Explicit diagnostic runtime arguments retain their existing behavior; never search PATH.
        let bundledDeno = javascriptRuntimeName == nil && javascriptRuntimePath == nil
            ? bundledDenoPath(bundleHelpersDirectory: bundleHelpersDirectory,
                managedHelpersDirectory: managedHelpersDirectory) : nil
        #if os(Windows)
        let runner: ScreenLinkProcessRunning = WindowsScreenLinkProcessRunner()
        #else
        let runner: ScreenLinkProcessRunning = PosixScreenLinkProcessRunner()
        #endif
        return ScreenLinkResolverService(
            locator: locator, runner: runner,
            javascriptRuntimeName: javascriptRuntimeName ?? (bundledDeno == nil ? nil : "deno"),
            javascriptRuntimePath: javascriptRuntimePath ?? bundledDeno
        )
    }

    static func bundledDenoPath(bundleHelpersDirectory: String?, managedHelpersDirectory: String?) -> String? {
        let locator = ScreenLinkHelperLocator(
            helperName: "deno", bundleHelpersDirectory: bundleHelpersDirectory,
            managedHelpersDirectory: managedHelpersDirectory,
            devOverridePath: nil, allowDevOverride: false
        )
        guard case let .found(location) = locator.locate() else { return nil }
        return location.path
    }

    // MARK: 解析

    func resolve(_ request: ScreenLinkRequest) async -> ScreenLinkResolution {
        let task = Task { [self] in await perform(request) }
        currentTask.withLock { $0 = task }
        // 外层任务被取消时，也把我们自己起的这一个取消掉（进程随之被终止）。
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        currentTask.withLock { if $0 == task { $0 = nil } }
        return result
    }

    /// 取消**当前**这次解析。没有在跑时是空操作。
    func cancel() {
        currentTask.withLock { $0?.cancel() }
    }

    // MARK: 实际流程

    private func perform(_ request: ScreenLinkRequest) async -> ScreenLinkResolution {
        // ① 入口判据：https + 受支持的公开观看页。裸 id / 官方嵌入页**不**走这里。
        let trimmed = request.pageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed(.emptyInput) }
        guard let url = URL(string: trimmed) else { return .failed(.malformedURL) }
        guard url.scheme?.lowercased() == "https" else {
            return .failed(.unsupportedScheme(url.scheme ?? ""))
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return .failed(.malformedURL)
        }
        guard ScreenLinkSitePolicy.accepts(trimmed) else {
            return .failed(.unsupportedSite(host))
        }

        // ② 定位内置辅助程序（不查 PATH）。
        let lookup = locator.locate()
        switch lookup {
        case let .missing(searched):
            return .failed(.missingHelper(searched: searched))
        case let .integrityFailure(failure):
            return .failed(failure)
        case let .found(location):
            return await run(location: location, request: request, pageURL: trimmed)
        }
    }

    private func run(
        location: ScreenLinkHelperLocation,
        request: ScreenLinkRequest,
        pageURL: String
    ) async -> ScreenLinkResolution {
        let invocation = YtDlpInvocation.make(
            request: ScreenLinkRequest(
                pageURL: pageURL,
                preferredMaximumHeight: request.preferredMaximumHeight,
                allowsSeparateStreams: request.allowsSeparateStreams,
                timeout: request.timeout
            ),
            executablePath: location.path,
            javascriptRuntimeName: javascriptRuntimeName,
            javascriptRuntimePath: javascriptRuntimePath
        )
        let processRequest = ScreenLinkProcessRequest(
            executablePath: invocation.executablePath,
            arguments: invocation.arguments,
            environment: controlledEnvironment(),
            workingDirectory: workingDirectory,
            timeout: request.timeout
        )
        let result = await runner.run(processRequest)
        if result.wasCancelled || Task.isCancelled { return .failed(.cancelled) }
        if result.timedOut { return .failed(.helperTimedOut) }
        if let launchFailure = result.launchFailure {
            return .failed(.helperLaunchFailed(launchFailure))
        }
        if result.terminationStatus != 0 {
            return .failed(
                YtDlpResultParser.failure(
                    terminationStatus: result.terminationStatus,
                    standardError: result.standardError
                ) ?? .helperFailed(code: result.terminationStatus, summary: "unknown")
            )
        }
        return YtDlpResultParser.parse(standardOutput: result.standardOutput, pageURL: pageURL)
    }

    /// 传给辅助程序的**受控环境**：
    ///
    /// - `PATH` 置空：它去找 ffmpeg / JS 运行时的时候**只能**用我们显式给的路径，
    ///   不会用用户机器上碰巧装着的那些；
    /// - `HOME` 指向受控工作目录：即便 `--ignore-config` 哪天失效，它也读不到
    ///   `~/.config/yt-dlp`；
    /// - 不继承 `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`（不绕地区，也不泄漏内网代理）；
    /// - `PYTHONNOUSERSITE=1` 阻止 PyInstaller 之外的 Python 用户站点包混进来。
    private func controlledEnvironment() -> [String: String] {
        var environment: [String: String] = [
            "PATH": "",
            "HOME": workingDirectory ?? NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PYTHONNOUSERSITE": "1",
        ]
        let inherited = ProcessInfo.processInfo.environment
        if let tmp = inherited["TMPDIR"], !tmp.isEmpty { environment["TMPDIR"] = tmp }
        return environment
    }
}
