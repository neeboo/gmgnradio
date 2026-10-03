import Foundation

// MARK: - 内置辅助程序的定位（**不查 PATH、不用 Homebrew、不读 cookies**）

/// 找到的那个辅助程序。
struct ScreenLinkHelperLocation: Equatable, Sendable {
    let path: String
    let version: String
    /// 来自开发覆盖（显式路径），不是随 app 分发的内置副本。
    let isDevOverride: Bool
    /// 内容与钉死的 sha256 一致。
    let isPinned: Bool
    let sha256: String
}

/// 定位结果。失败是**具名**的。
enum ScreenLinkHelperLookup: Equatable, Sendable {
    case found(ScreenLinkHelperLocation)
    /// 受控查找位置都没有。`searched` 是**我们找过的**那些路径（不是用户 PATH）。
    case missing(searched: [String])
    case integrityFailure(ScreenLinkFailure)
}

/// 「内置辅助程序在哪、对不对」的**唯一**一处。
///
/// ## 受控查找顺序（**没有一项来自用户 PATH**）
///
/// 1. **开发覆盖**：调用方显式给的绝对路径（探针/开发验证用；默认关闭，且要求
///    绝对路径 + 可执行）。它**不**扫 PATH —— 于是"用户机器上装了 Homebrew yt-dlp"
///    不会变成产品依赖。
/// 2. **app 内置**：`<bundle>/Contents/Helpers/<name>`（`tools/bundle-…` 打包脚本的落点）。
/// 3. **受管目录**：`~/Library/Application Support/gmgn radio/Helpers/<name>`
///    （受控更新时替换；同样是我们自己写的，不是用户装的）。
///
/// 找到之后**生产副本必须**与 `BundledHelperManifest` 里钉死的 sha256 逐字节一致；
/// 清单里没钉哈希（空串）时生产路径直接拒绝执行（具名 `helperIntegrityMismatch`）。
/// **唯一例外**是显式开发覆盖（调用方给出的绝对路径）：它绕过内置副本的哈希钉死，
/// 但回执如实标出 `isDevOverride`，生产（`allowDevOverride == false`）永远走不到。
/// 这样"忘了钉哈希"不会悄悄变成一条生产可执行路径。
///
/// 刻意**不声明 `Sendable`**：它拿着一份 `FileManager`（不是 Sendable），而唯一的使用者
/// `ScreenLinkResolverService` 已经是 `@unchecked Sendable` 且只在主流程里同步调它。
struct ScreenLinkHelperLocator {
    var helperName: String = "yt-dlp"
    var manifest: BundledHelperManifest = .pinned
    var bundleHelpersDirectory: String?
    var managedHelpersDirectory: String?
    /// 开发覆盖的绝对路径（来自显式配置，不是 PATH 查询）。
    var devOverridePath: String?
    /// 是否允许开发覆盖。生产传 `false`。
    var allowDevOverride: Bool
    var fileManager: FileManager = .default

    /// 受控查找位置（**顺序即优先级**；用于具名失败里的 `searched`）。
    var searchPaths: [String] {
        var paths: [String] = []
        if allowDevOverride, let devOverridePath, !devOverridePath.isEmpty {
            paths.append(devOverridePath)
        }
        if let bundleHelpersDirectory {
            paths.append(bundleHelpersDirectory + "/" + helperName)
        }
        if let managedHelpersDirectory {
            paths.append(managedHelpersDirectory + "/" + helperName)
        }
        return paths
    }

    func locate() -> ScreenLinkHelperLookup {
        guard let expected = manifest.helper(named: helperName) else {
            return .missing(searched: searchPaths)
        }
        let candidates = searchPaths
        guard !candidates.isEmpty else { return .missing(searched: []) }
        for (index, path) in candidates.enumerated() {
            guard fileManager.isExecutableFile(atPath: path) else { continue }
            let isDev = allowDevOverride && index == 0 && devOverridePath == path
            guard let actual = ScreenLinkIntegrity.sha256Hex(ofFileAt: path) else {
                return .integrityFailure(.helperNotExecutable(path))
            }
            // **开发覆盖优先**：调用方显式给的绝对路径是"我就是要跑这一份"。它绕过
            // 内置副本的哈希钉死（正是开发覆盖存在的意义），但回执**如实**标出
            // `isDevOverride`，并且只有当它恰好与钉死摘要一致时 `isPinned` 才为真。
            // 生产（`allowDevOverride == false`）永远走不到这一支。
            if isDev {
                return .found(ScreenLinkHelperLocation(
                    path: path, version: expected.version,
                    isDevOverride: true, isPinned: actual == expected.sha256, sha256: actual
                ))
            }
            if expected.isPinned {
                guard actual == expected.sha256 else {
                    return .integrityFailure(.helperIntegrityMismatch(
                        expected: expected.sha256, actual: actual
                    ))
                }
                return .found(ScreenLinkHelperLocation(
                    path: path, version: expected.version,
                    isDevOverride: false, isPinned: true, sha256: actual
                ))
            }
            // 清单里没钉哈希：生产副本一律拒绝执行（宁可放不了，也不跑未校验的东西）。
            return .integrityFailure(.helperIntegrityMismatch(
                expected: "(unpinned)", actual: actual
            ))
        }
        return .missing(searched: candidates)
    }

    /// app 内置目录（`Contents/Helpers`）。在 bundle 之外（探针/测试）返回 `nil`。
    static func defaultBundleHelpersDirectory(bundle: Bundle = .main) -> String? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        return resourceURL.deletingLastPathComponent()
            .appendingPathComponent("Helpers", isDirectory: true).path
    }

    /// 受管目录（受控更新落点）。
    static func defaultManagedHelpersDirectory(fileManager: FileManager = .default) -> String? {
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return support
            .appendingPathComponent("gmgn radio", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true).path
    }

    /// 从环境读开发覆盖路径。**只读一个显式变量**，绝不是 PATH。
    static func devOverridePath(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> String?
    {
        environment["GMGN_SCREEN_LINK_HELPER"]
    }
}
