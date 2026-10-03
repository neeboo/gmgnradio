import Foundation

/// 显式测试运行时（`GMGN_E2E_DATA_ROOT`）。
///
/// 这是**唯一**一处把"这次启动是隔离测试宿主"翻译成路径/偏好域的开关。
/// 生产默认**逐字节不变**：
///
/// - 没设 `GMGN_E2E_DATA_ROOT` ⇒ `isolationRequested == false`、`isEnabled == false`、
///   `applicationSupportBase == nil`，所有显式访问器都回落到真实用户目录；
/// - 环境变量 + **专用测试 bundle id** 同时成立 ⇒ 应用支撑目录、缓存目录、控制收/发件箱、
///   证据目录全部落在该根下；
/// - 环境变量成立但**不是**专用测试产物 ⇒ 启动即 fail-closed 退出（`exit(78)`），
///   绝不"半隔离"地回落到真实用户目录（上一轮的拒收项：bootstrap 失败不能回落写生产）。
///
/// ## 为什么不靠 `CFFIXED_USER_HOME`
///
/// 本机实测：`CFFIXED_USER_HOME` 在进程启动后再设置，**不能保证** Foundation 既有的
/// home / caches 解析与 `UserDefaults` 一定跟着换。所以隔离的机械保证是**显式根注入**：
/// 每一个 file 持久化点都从 `E2ERuntime.applicationSupportDirectory` /
/// `.cachesDirectory` / `.homeDirectory` 取根（生产时它们就是真实目录），而不是让
/// Foundation 去猜。`CFFIXED_USER_HOME` 仍然设置，作为第三方框架（WebKit/SceneKit）
/// 的额外一层，但**不再是任何判据的前提**。
///
/// ## UserDefaults：每个测试根一个稳定 suite
///
/// 固定 suite（上一轮的 `ai.gmgn.radio.e2e`）会在**重复验收之间互相污染**：上一次跑
/// 留下的键会出现在下一次。这里改成 `每个测试根的路径` 派生一个 suite 名：同一个根
/// 重启保持不变（重启恢复判据因此成立），不同根天然隔离（重复验收不串）。
enum E2ERuntime {
    static let dataRootEnvironmentKey = "GMGN_E2E_DATA_ROOT"
    /// 控制目录名（相对测试根）。收件箱由驱动器写、宿主读；发件箱反过来。
    static let controlDirectoryName = "control"
    static let inboxDirectoryName = "inbox"
    static let outboxDirectoryName = "outbox"
    static let evidenceDirectoryName = "evidence"
    /// 控制面就绪标记：宿主写完才置位，驱动器据此确认"可以下命令了"。
    static let readyMarkerName = "ready"
    static let stoppedMarkerName = "stopped"

    /// 测试根：未设置/invalid 为 nil。仅做字符串解析，不碰磁盘。
    static var dataRoot: URL? {
        guard let raw = ProcessInfo.processInfo.environment[dataRootEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            raw.hasPrefix("/")
        else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    /// 生产 bundle id。
    static let productionBundleIdentifier = "ai.gmgn.radio"
    /// 专用测试产物的 bundle id（`tools/e2e-app-build.sh` 设
    /// `PRODUCT_BUNDLE_IDENTIFIER`）。
    static let testBundleIdentifier = "ai.gmgn.radio.e2e"

    /// 调用方**表达了隔离意图**（设了根），无论产物对不对。
    static var isolationRequested: Bool { dataRoot != nil }

    /// 真正启用隔离测试：既设了根，又是**专用测试产物**。
    static var isEnabled: Bool {
        dataRoot != nil && Bundle.main.bundleIdentifier == testBundleIdentifier
    }

    /// 没启用的具名原因（日志与驱动器用）。
    static var disabledReason: String? {
        guard let root = dataRoot else { return nil }
        guard Bundle.main.bundleIdentifier != testBundleIdentifier else { return nil }
        return "GMGN_E2E_DATA_ROOT 已设（\(root.path)），但这不是专用测试产物"
            + "（bundle id=\(Bundle.main.bundleIdentifier ?? "nil")）；已拒绝隔离启动。"
    }

    // MARK: - 显式根（所有 file 持久化的唯一取根处）

    /// 生产 `nil`（调用方回落到 `FileManager` 的真实 Application Support）；
    /// 测试 `<root>/Library/Application Support`。
    ///
    /// 注意：这里给的是 **Application Support 本身**，不是它下面某个 app 目录 ——
    /// 既有调用方会各自再拼 `gmgn radio` / bundle id；保持同一口径，隔离根才不会因为
    /// 某个调用方少拼一层而漏到真实目录。
    static var applicationSupportBase: URL? {
        guard isEnabled else { return nil }
        return dataRoot?.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// **非可选**的 Application Support 取根口：测试走隔离根，生产走真实目录。
    /// 这是"显式 root 注入"的默认落点，file 持久化应优先用它。
    static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
        if let base = applicationSupportBase { return base }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// **非可选**的 Caches 取根口。
    static func cachesDirectory(fileManager: FileManager = .default) -> URL {
        if let root = dataRoot, isEnabled {
            return root.appendingPathComponent("Library/Caches", isDirectory: true)
        }
        return fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// **非可选**的 home 取根口（配置文件、secrets 都在它下面）。
    static func homeDirectory(fileManager: FileManager = .default) -> URL {
        if let root = dataRoot, isEnabled { return root }
        return fileManager.homeDirectoryForCurrentUser
    }

    /// 受管 helper 目录的根（`<home>/Library/Application Support/gmgn radio` 的上一层口径）。
    static func productSupportDirectory(fileManager: FileManager = .default) -> URL {
        applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("gmgn radio", isDirectory: true)
    }

    // MARK: - UserDefaults：每个测试根一个稳定 suite

    /// 隔离后的偏好域。
    ///
    /// 生产恒为 `.standard`。测试时按**测试根路径**派生一个稳定 suite 名：
    /// - 同一个根（含重启）= 同一个 suite ⇒ 重启保留；
    /// - 不同根 = 不同 suite ⇒ 重复验收不互相污染。
    static var defaults: UserDefaults {
        guard isEnabled, let root = dataRoot else { return .standard }
        return UserDefaults(suiteName: suiteName(forRoot: root)) ?? .standard
    }

    /// 从测试根路径派生 suite 名。FNV-1a（64 位）足以避免不同路径撞名，且不引入
    /// CryptoKit 依赖、跨进程确定。
    static func suiteName(forRoot root: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in root.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "ai.gmgn.radio.e2e." + String(hash, radix: 16)
    }

    static var controlRoot: URL? { isEnabled ? dataRoot?.appendingPathComponent(controlDirectoryName, isDirectory: true) : nil }
    static var inboxRoot: URL? { controlRoot?.appendingPathComponent(inboxDirectoryName, isDirectory: true) }
    static var outboxRoot: URL? { controlRoot?.appendingPathComponent(outboxDirectoryName, isDirectory: true) }
    static var evidenceRoot: URL? { isEnabled ? dataRoot?.appendingPathComponent(evidenceDirectoryName, isDirectory: true) : nil }

    // MARK: - bootstrap

    /// 是否已经完成 bootstrap（避免重复 setenv / 重复建目录）。
    private static let bootstrapLock = NSLock()
    nonisolated(unsafe) private static var bootstrapped = false
    nonisolated(unsafe) private(set) static var bootstrapError: String?

    /// 在应用最早的时刻调用一次。返回是否"测试运行时可用"。
    ///
    /// 副作用只在显式启用（`isEnabled`：环境变量 + 专用测试 bundle id 同时成立）
    /// 时发生：建目录、设 `CFFIXED_USER_HOME`。生产路径是零副作用。
    ///
    /// **fail-closed**：一旦"设了根但隔离不成立"或"根建不出来"，直接退出，绝不返回
    /// false 让调用方回落到生产目录（上一轮拒收项）。
    @discardableResult
    static func bootstrap(fileManager: FileManager = .default) -> Bool {
        guard isolationRequested else { return false }
        guard isEnabled, let root = dataRoot else {
            failClosed(disabledReason ?? "测试运行时不可用")
        }
        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }
        if bootstrapped {
            if let bootstrapError { failClosed(bootstrapError) }
            return true
        }
        bootstrapped = true

        // Foundation 用 CFFIXED_USER_HOME 决定 NSHomeDirectory() / Application Support。
        // 这是给第三方框架（WebKit/SceneKit）的额外一层；本工程的持久化不依赖它，
        // 一律走上面的显式访问器。
        if ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]?.isEmpty != false {
            setenv("CFFIXED_USER_HOME", root.path, 1)
        }

        var directories = [root]
        directories.append(root.appendingPathComponent("Library/Preferences", isDirectory: true))
        directories.append(applicationSupportDirectory(fileManager: fileManager))
        directories.append(cachesDirectory(fileManager: fileManager))
        if let control = controlRoot { directories.append(control) }
        if let inbox = inboxRoot { directories.append(inbox) }
        if let outbox = outboxRoot { directories.append(outbox) }
        if let evidence = evidenceRoot { directories.append(evidence) }
        // secrets 目录是生成服务配置的落点（驱动器注入、App 读取）。
        directories.append(
            applicationSupportDirectory(fileManager: fileManager)
                .appendingPathComponent("ai.gmgn.radio/secrets", isDirectory: true)
        )

        do {
            for directory in directories {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        } catch {
            bootstrapError = "测试数据根不可用：\(error.localizedDescription)"
            failClosed(bootstrapError!)
        }

        // 每个测试根**首次**启动时清掉上一轮固定 e2e 域留下的键；之后同一根重启不再清，
        // 于是"重复验收不串、同根重启保留"两件事同时成立。遗留键来自上一轮的固定 suite
        // `ai.gmgn.radio.e2e`（真实偏好文件），不清就会跨验收污染。
        let initializationMarker = root.appendingPathComponent(
            ".defaults-suite-initialized", isDirectory: false
        )
        if !fileManager.fileExists(atPath: initializationMarker.path) {
            UserDefaults.standard.removePersistentDomain(forName: testBundleIdentifier)
            let suite = suiteName(forRoot: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? Data("initialized \(Date().timeIntervalSince1970)\n".utf8)
                .write(to: initializationMarker, options: .atomic)
        }

        bootstrapError = nil
        return true
    }

    /// 隔离被要求却不成立：把原因写 stderr 后以配置错误码退出。
    /// 这是**唯一**允许的失败形态 —— 绝不继续用生产根运行测试。
    private static func failClosed(_ reason: String) -> Never {
        let message = "[GMGN_E2E] fail-closed: \(reason)\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(78) // EX_CONFIG
    }

    /// 统一的"应用支撑根"解析：生产走真实 Application Support，测试走隔离根。
    /// 拿不到目录时如实抛错，绝不静默落到真实用户目录。
    static func resolvedApplicationSupportBase(
        fileManager: FileManager = .default
    ) throws -> URL {
        if let base = applicationSupportBase { return base }
        return try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }
}
