import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - 内置辅助程序的**固定版本 / 校验 / 许可清单**

/// 受控版本的**内置辅助程序清单**（唯一一处）。
///
/// ## 为什么必须固定版本 + 校验
///
/// 网站解析器是要跟着网站变化的，所以它必须能更新；但**用户侧不许出现命令行、配置、
/// PATH 依赖**。于是：
/// - 程序**随 app 走**（`Contents/Helpers/` 或受管目录），不从 PATH 找、不用 Homebrew、
///   不导入浏览器 cookies；
/// - 版本是**钉死的**，升级是**我们**发布一次新的受控版本，不是运行时去 `--update`；
/// - 每个内置文件都带 sha256，运行时先校验再执行。
///
/// ## 许可：**别只看 Unlicense**
///
/// 事实（官方 README「Licensing」原文，2026-10-03 核对）：
/// - yt-dlp 源码仓库 / sdist / wheel：**Unlicense**（public domain）；
/// - **PyInstaller 打包的独立可执行文件**（`yt-dlp_macos` 这一族）：**内含 GPLv3+ 代码，
///   整个组合作品按 GPLv3+ 分发**。所以"内置一个官方 macOS 独立二进制"就等于把
///   GPLv3+ 义务带进 app；它**不是**一条"Unlicense 随便用"的路；
/// - zipimport 的 `yt-dlp` 与源码 tarball：含 **ISC**（meriyah）与 **MIT**（astring）代码；
/// - **`yt-dlp-ejs`**（YouTube 完整支持所需）是 Unlicense，但内含 MIT/ISC，且需要一个
///   JavaScript 运行时（deno / node / bun / QuickJS，官方推荐 deno）来执行；
/// - `ffmpeg` / `ffprobe`：合并分轨时需要，**许可随构建而变**（部分构建是 GPL）。
///
/// 因此本清单显式区分 `upstreamLicenseSPDX` 与 `combinedWorkLicenseSPDX`，并要求
/// `noticesFileRequired`：**任何随 app 分发的内置程序都必须带第三方许可声明**。
/// 这一条由 `tools/test-screen-link-resolver.swift` 的判据钉住（不许把 GPL 组合作品写成
/// 只有 Unlicense）。
struct BundledHelperManifest: Equatable, Sendable {
    /// 辅助文件的**分发形态**。它决定许可义务，不是一个可以忽略的标签。
    enum Distribution: String, Equatable, Sendable {
        /// 源码 / zipimport（Unlicense 上游 + MIT/ISC 组件）。
        case upstreamSource = "upstream_source"
        /// PyInstaller 独立二进制：**组合作品 GPLv3+**。
        case pyinstallerStandalone = "pyinstaller_standalone"
        /// 受管的 JavaScript 运行时（YouTube 解签需要）。
        case javascriptRuntime = "javascript_runtime"
    }

    struct Helper: Equatable, Sendable {
        /// 受控名字（也是内置目录里的文件名）。
        let name: String
        /// 钉死的版本。
        let version: String
        /// 钉死的 sha256（小写十六进制）。空串 = **没有钉**（只允许开发覆盖）。
        let sha256: String
        let distribution: Distribution
        /// 官方发布页（打包脚本照它取；运行时不联网取）。
        let sourceURL: String
        /// 上游自己的许可。
        let upstreamLicenseSPDX: String
        /// **实际分发的组合作品**的许可。独立二进制这里必须与上游不同。
        let combinedWorkLicenseSPDX: String
        let licenseNote: String

        var isPinned: Bool { sha256.count == 64 && sha256.allSatisfy(\.isHexDigit) }
    }

    struct Component: Equatable, Sendable {
        let name: String
        let licenseSPDX: String
        let note: String
    }

    let helpers: [Helper]
    /// 随内置程序一起进来的第三方组件（许可声明必须覆盖它们）。
    let components: [Component]
    /// 是否必须随分发带上第三方许可声明文件。
    let noticesFileRequired: Bool
    /// 声明文件在仓库里的相对路径（打包脚本读它）。
    let noticesPath: String

    func helper(named name: String) -> Helper? {
        helpers.first { $0.name == name }
    }

    /// 运行时的**受控版本清单**。真正取二进制、填 sha256 的是打包脚本
    /// （`tools/bundle-screen-link-helper.py`，直接写 `Contents/Helpers/` 与清单里的哈希）。
    ///
    /// 这里的每一处版本 / sha256 / 许可都与仓库钉死的打包清单
    /// `tools/helpers/screen-link-helpers.lock.json` **逐字段一致**，由
    /// `tools/test-screen-link-helper-lock.swift` 机械核对。空 sha256 表示"尚未钉"：
    /// 定位器在**生产模式**下会因此拒绝执行（具名 `helperIntegrityMismatch`），只有显式的
    /// 开发覆盖路径才允许跑未钉的副本。可执行的 helper（`yt-dlp`）**不许**留空哈希。
    static let pinned = BundledHelperManifest(
        helpers: [
            Helper(
                name: "yt-dlp",
                version: "2026.08.19",
                sha256: "0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202",
                distribution: .pyinstallerStandalone,
                sourceURL: "https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_macos",
                upstreamLicenseSPDX: "Unlicense",
                combinedWorkLicenseSPDX: "GPL-3.0-or-later",
                licenseNote:
                    "yt-dlp 上游是 Unlicense；PyInstaller 独立二进制内含 GPLv3+ 代码，"
                    + "组合作品按 GPLv3+ 分发。分发时必须带第三方许可声明。"
            ),
            Helper(
                name: "deno",
                version: "2.9.7",
                sha256: "b73737579d5a84c160e3316487594783fa5c15f4e13252a6a07050b755317f1a",
                distribution: .javascriptRuntime,
                sourceURL: "https://github.com/denoland/deno/releases/download/v2.9.7/deno-aarch64-apple-darwin.zip",
                upstreamLicenseSPDX: "MIT",
                combinedWorkLicenseSPDX: "MIT",
                licenseNote:
                    "官方推荐的 JavaScript 运行时，用于执行 yt-dlp-ejs 解 YouTube 的 nsig。"
                    + "版本与哈希在打包清单里钉死；默认不随包。"
            ),
        ],
        components: [
            Component(
                name: "meriyah", licenseSPDX: "ISC",
                note: "随 yt-dlp 的 zipimport / tarball 分发（JavaScript 解析器）。"
            ),
            Component(
                name: "astring", licenseSPDX: "MIT",
                note: "随 yt-dlp 的 zipimport / tarball 分发（AST 生成）。"
            ),
            Component(
                name: "yt-dlp-ejs", licenseSPDX: "Unlicense",
                note: "YouTube 完整支持所需；它是**源码树**（内置 MIT astring / ISC meriyah），"
                    + "没有单文件 sha256，所以不作 helper 打包，只作许可与版本登记。"
            ),
            Component(
                name: "Python", licenseSPDX: "PSF-2.0",
                note: "独立二进制内含 Python 解释器。"
            ),
            Component(
                name: "ffmpeg", licenseSPDX: "LGPL-2.1-or-later / GPL-2.0-or-later",
                note: "本 App 不内置 ffmpeg；分轨合并由 AVFoundation 完成。"
            ),
        ],
        noticesFileRequired: true,
        noticesPath: "apps/macos/Resources/Helpers/THIRD_PARTY_LICENSES.txt"
    )
}

// MARK: - sha256 校验

/// 文件内容的 sha256（小写十六进制）。**跨平台的算法**，实现按平台选 CryptoKit。
enum ScreenLinkIntegrity {
    /// 计算一个文件的 sha256。文件读不出来返回 `nil`（调用方报具名失败）。
    static func sha256Hex(ofFileAt path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return sha256Hex(of: data)
    }

    static func sha256Hex(of data: Data) -> String? {
        #if canImport(CryptoKit)
        var hasher = SHA256()
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }
}
