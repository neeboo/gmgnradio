// ---------------------------------------------------------------------------
// 小窗（LiveCam）里**没有任何元素遮挡别的控件**。
//
// 用户 2026-10-02 原话：
//   「小窗也是不要有遮挡」
// 截图证据：小窗里那块「许愿任务」条压住了右下角的设置按钮。
//
// 判据不是"读源码猜"，而是**真实 AppKit 布局**：
//   ① 屏幕上的每个控件，在自己中心点的 `hitTest` 结果必须是它自己（或它的子视图）
//      —— 被别的元素盖住 / 抢走命中，这一条就红；
//   ② 直接子视图里那些**覆盖块**（玻璃面板 / 宿主视图 / 横幅）的 frame 不许与
//      **任何**控件的 frame 相交（祖先包含关系不算 —— 容器本来就该包住自己的按钮）。
//   ③ 顺手打印整棵视图树的 frame（**层级清单**），数字就是证据。
//
// 三个模式（注入只改**内存 / 临时副本**，落盘的产品源码一个字不改）：
//   swift tools/test-livecam-no-occlusion.swift                     ← 产品路径，必须 PASS
//   LIVECAM_OCCLUSION_FROM_HEAD=1 swift tools/test-livecam-no-occlusion.swift
//       用 `git show HEAD:` 那一份 `LiveCamPanel.swift` + `StageOverlayView.swift` 编译
//       （= 改前），必须 FAIL —— 这是"这条判据真的抓得住那个缺陷"的负对照。
//   LIVECAM_OCCLUSION_INJECT=cover-controls swift tools/test-livecam-no-occlusion.swift
//       往临时副本里注入一个盖住控件列的元素，必须 FAIL。
// ---------------------------------------------------------------------------
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let fromHead = ProcessInfo.processInfo.environment["LIVECAM_OCCLUSION_FROM_HEAD"] == "1"
let injection = ProcessInfo.processInfo.environment["LIVECAM_OCCLUSION_INJECT"]

var failureCount = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("PASS \(message)")
    } else {
        print("FAIL \(message)")
        failureCount += 1
    }
}

/// 读一份源码：`FROM_HEAD` 时读 HEAD 那一版（临时在内存里，不落盘产品源码）。
func source(_ relative: String) throws -> String {
    if fromHead {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["show", "HEAD:apps/macos/Sources/GMGNRadio/\(relative)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "harness", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "git show HEAD:\(relative) 失败"])
        }
        return String(decoding: data, as: UTF8.self)
    }
    return try String(contentsOf: sources.appendingPathComponent(relative), encoding: .utf8)
}

func declaration(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{") else {
        fatalError("抽不出声明：\(signature)")
    }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("声明括号不配对：\(signature)")
}

/// 只在源码里真的有这段声明时才抽它。
///
/// 为什么需要：产品路径上「什么时候占屏幕」那条判据已经搬去
/// `Presence/WishMachineTaskMessage.swift`（许愿任务不再有自己的列表），
/// `WishMachineTaskStatusView` 不再引用它；而**改前**那一份（`FROM_HEAD`）引用的正是它。
/// 负对照要能编译，所以这里按"有没有"取，而不是把两边的源码改成一样。
func optionalDeclaration(_ signature: String, in source: String) -> String {
    source.contains(signature) ? declaration(signature, in: source) + "\n@MainActor\n" : ""
}

// 依赖：与 `tools/test-livecam-panel-sizing.swift` 同一份抽取清单（那个 harness 已经
// 证明这一套能编译 LiveCamPanel）。面板里出现的每一个跨文件声明都必须抽到，
// 否则编译只会报 "cannot find type" 并把断言整条编译掉。
func dependencySource() throws -> String {
    let overlay = try source("VisualEngine/StageOverlayView.swift")
    return "import SwiftUI\nimport Observation\n"
        + declaration("enum LocalMusicPlaybackState:", in: try source("AudioEngine/LocalMusicPlayer.swift")) + "\n"
        + declaration("enum ProgramPlaybackToggleRoute:", in: try source("AudioEngine/ProgramPlaybackQueue.swift")) + "\n"
        + declaration("enum RealtimeVoiceConnectionState:", in: try source("Settings/AgentSettingsModel.swift")) + "\n"
        + declaration("enum ResidentStatusNoticeKind:", in: try source("Agent/ResidentAgentLoop.swift")) + "\n"
        + declaration("struct ResidentStatusNoticeDecision:", in: try source("Agent/ResidentAgentLoop.swift")) + "\n"
        + declaration("enum ResidentStatusNoticeMerge", in: try source("Agent/ResidentAgentLoop.swift")) + "\n"
        + declaration("enum LiveCamWindowDragPhase:", in: try source("DesktopPresence/WindowPlacement.swift")) + "\n"
        + declaration("struct ResidentChatTurn:", in: try source("Agent/ResidentAgentLoop.swift")) + "\n"
        + declaration("struct ResidentChatTranscriptLine:", in: try source("Agent/ResidentAgentLoop.swift")) + "\n@MainActor\n"
        + declaration("final class ResidentSystemMailBadgeButton: NSView {", in: try source("Presence/ResidentSystemInboxUI.swift")) + "\n@MainActor\n@Observable\n"
        + declaration("final class AgentSpeechStatusStore", in: try source("Agent/AgentSpeech.swift")) + "\n@MainActor\n"
        + declaration("struct ResidentSpeechErrorNotice:", in: overlay) + "\n"
        + optionalDeclaration("enum WishMachineTaskPrompt", in: overlay)
        + declaration("struct WishMachineTaskStatusView:", in: overlay)
}

// ---------------------------------------------------------------------------
// 产品源码（或它的临时副本）：注入只改这一份字符串，落盘的源码一个字不改。
// ---------------------------------------------------------------------------
var panelSource = try source("DesktopPresence/LiveCamPanel.swift")
if injection == "cover-controls" {
    let anchor = "addSubview(controls)"
    guard let range = panelSource.range(of: anchor) else {
        fatalError("注入点不见了：\(anchor)")
    }
    let cover = anchor + """

        // ── 注入负对照（只在临时副本里）：一块盖住整个控件列的元素 ──
        let injectedCover = NSView()
        injectedCover.wantsLayer = true
        injectedCover.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.9).cgColor
        injectedCover.translatesAutoresizingMaskIntoConstraints = false
        injectedCover.identifier = NSUserInterfaceItemIdentifier("livecam.injected-cover")
        addSubview(injectedCover)
        NSLayoutConstraint.activate([
            injectedCover.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -12),
            injectedCover.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            injectedCover.topAnchor.constraint(equalTo: controls.topAnchor),
            injectedCover.bottomAnchor.constraint(equalTo: controls.bottomAnchor),
        ])
        """
    panelSource.replaceSubrange(range, with: cover)
}

// ---------------------------------------------------------------------------
// 被测 harness 本体
// ---------------------------------------------------------------------------
let testSource = #"""
import AppKit
import SwiftUI

@main struct Tests {
    @MainActor static func main() async {
        _ = NSApplication.shared
        var count = 0, failures = 0
        var retained: [LiveCamPanel] = []
        func check(_ condition: Bool, _ text: String) {
            count += 1
            if !condition { failures += 1; print("FAIL: \(text)") }
        }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        func identifier(_ view: NSView) -> String {
            if let value = view.identifier?.rawValue, !value.isEmpty { return value }
            let accessible = view.accessibilityIdentifier()
            if !accessible.isEmpty { return accessible }
            return String(describing: type(of: view))
        }
        /// 缩进的**层级清单**：每一层的 frame / 可见性就是证据。
        func dumpTree(_ view: NSView, depth: Int) -> [String] {
            view.subviews.flatMap { child -> [String] in
                [String(format: "%@%@ frame=%@ hidden=%@",
                        String(repeating: "  ", count: depth),
                        identifier(child) as NSString,
                        NSStringFromRect(child.frame) as NSString,
                        child.isHidden ? "yes" : "no")] + dumpTree(child, depth: depth + 1)
            }
        }
        /// 这一支是不是"可见"（自己和所有祖先都没被隐藏）。
        func visible(_ view: NSView, upTo stop: NSView) -> Bool {
            var node: NSView? = view
            while let current = node {
                if current.isHidden { return false }
                if current === stop { return true }
                node = current.superview
            }
            return true
        }
        func isDescendant(_ view: NSView, of ancestor: NSView) -> Bool {
            var node: NSView? = view
            while let current = node {
                if current === ancestor { return true }
                node = current.superview
            }
            return false
        }
        /// 「控件」= 用户真的能点的东西：按钮 + 可编辑输入框。
        func isControl(_ view: NSView) -> Bool {
            if let button = view as? NSButton { return !button.isHidden }
            if let field = view as? NSTextField { return field.isEditable && !field.isHidden }
            return false
        }
        /// 「覆盖块」= 直接铺在面板上、会盖住别人的东西（玻璃面板 / SwiftUI 宿主）。
        func isOverlay(_ view: NSView) -> Bool {
            view is NSVisualEffectView || view is NSHostingView<AnyView> || type(of: view).description().contains("NSHostingView")
        }

        let cases: [(String, CGSize)] = [("224x336", CGSize(width: 224, height: 336)),
                                         ("320x240", CGSize(width: 320, height: 240))]
        for (label, requested) in cases {
            let surface = NSView()
            let panel = LiveCamPanel(frame: CGRect(origin: .zero, size: requested), contentView: surface)
            retained.append(panel)
            panel.isReleasedWhenClosed = false
            panel.interactionView.onComposerVisibilityChanged = { _ in }

            // **最坏情形**：所有可能出现的元素都出现 —— 许愿任务（非终态 ⇒ 常驻那一档）、
            // 全局连通性横幅、送达提示，以及展开的对话（输入框 + 全部按钮）。
            panel.interactionView.setWishMachineConnectivity("连不上后台（network_unavailable）。任务和产物都还在，恢复后会自己继续；这条提示会自动消失。")
            panel.interactionView.setWishMachineTasks([
                WishMachineTaskPresentation(
                    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
                    title: "超大荧幕电视", status: "生成中", detail: nil,
                    isTerminal: false, axes: nil, promptExpiresAt: nil),
                WishMachineTaskPresentation(
                    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!,
                    title: "暖光落地灯", status: "未领取", detail: nil,
                    isTerminal: false, axes: nil, promptExpiresAt: nil)
            ])
            panel.interactionView.setResidentDeliveryNotice("有补充消息尚未确认送达，未重复发送。")
            panel.interactionView.setResidentAutonomyStop(true)
            if !panel.interactionView.isComposerVisible {
                panel.interactionView.chatButton.performClick(nil)
            }
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(20))
                panel.contentView?.needsLayout = true
                panel.contentView?.layoutSubtreeIfNeeded()
            }

            // ── 层级清单（数字就是证据）──
            print("HIERARCHY \(label) panel=\(panel.frame.size) interaction=\(panel.interactionView.frame.size)")
            let all = descendants(panel.interactionView)
            for line in dumpTree(panel.interactionView, depth: 1) { print("  " + line) }

            let visibleControls = all.filter { isControl($0) && visible($0, upTo: panel.interactionView) }
            check(visibleControls.count >= 6, "\(label) 控件清单非空（\(visibleControls.count) 个可见控件）")
            let buttons = visibleControls.map { identifier($0) }
            for name in ["livecam.button.settings", "livecam.button.chat", "livecam.button.voice",
                         "livecam.button.space", "livecam.button.player"] {
                check(buttons.contains(name), "\(label) 控件清单里有 \(name)")
            }

            // ── ① 命中判据：每个控件的中心必须自己（或自己的子视图）接下这一下 ──
            for control in visibleControls {
                let point = NSPoint(x: control.bounds.midX, y: control.bounds.midY)
                let inSelf = control.convert(point, to: panel.interactionView)
                guard let hit = panel.interactionView.hitTest(inSelf) else {
                    check(false, "\(label) \(identifier(control)) 的中心点没有命中任何东西（被覆盖块盖住）")
                    continue
                }
                check(isDescendant(hit, of: control),
                      "\(label) \(identifier(control)) 的中心被 \(identifier(hit)) 抢走命中")
            }

            // ── ② 几何判据：覆盖块不许与任何控件相交（祖先包含不算）──
            let directChildren = panel.interactionView.subviews
            for overlay in directChildren where isOverlay(overlay) && visible(overlay, upTo: panel.interactionView) {
                let overlayFrame = overlay.convert(overlay.bounds, to: panel.interactionView)
                for control in visibleControls where !isDescendant(control, of: overlay) {
                    let controlFrame = control.convert(control.bounds, to: panel.interactionView)
                    let overlap = overlayFrame.intersection(controlFrame)
                    check(overlap.isNull || overlap.isEmpty,
                          "\(label) 覆盖块 \(identifier(overlay)) \(NSStringFromRect(overlayFrame))"
                          + " 与控件 \(identifier(control)) \(NSStringFromRect(controlFrame))"
                          + " 相交 \(NSStringFromRect(overlap))")
                }
            }
        }
        print("\(failures == 0 ? "PASS" : "FAIL"): 小窗遮挡判据 \(count) 条，\(failures) 条不通过")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-livecam-occlusion-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }
let deps = directory.appendingPathComponent("Dependencies.swift")
let tests = directory.appendingPathComponent("Tests.swift")
let panel = directory.appendingPathComponent("LiveCamPanel.swift")
let binary = directory.appendingPathComponent("tests")
try dependencySource().write(to: deps, atomically: true, encoding: .utf8)
try testSource.write(to: tests, atomically: true, encoding: .utf8)
try panelSource.write(to: panel, atomically: true, encoding: .utf8)

func run(_ path: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

let attachments = ["App/E2ERuntime.swift", "VisualEngine/ResidentStatusBadge.swift", "Presence/ResidentImageAttachment.swift",
                   "Presence/PropImagePreparation.swift", "Presence/PropGenerationClient.swift",
                   "Presence/WishMachineTaskPresentation.swift", "Presence/ResidentOwnershipProjection.swift"]
    .map { sources.appendingPathComponent($0).path }
let compiled = try run("/usr/bin/swiftc",
    ["-disable-sandbox", "-j1", "-parse-as-library", "-target", "arm64-apple-macos14.0",
     panel.path, deps.path, tests.path, "-o", binary.path] + attachments)
guard compiled == 0 else {
    print("FAIL: 小窗遮挡 harness 编译失败（退出码 \(compiled)）")
    exit(compiled)
}
if CommandLine.arguments.contains("--compile-only") {
    print("PASS: 小窗遮挡 harness 编译通过（不启动 AppKit 运行时）")
    exit(0)
}
let status = try run(binary.path, [])
if fromHead {
    check(status != 0, "负对照「改前的 LiveCamPanel + HEAD 的许愿任务条」必须红（证明这条判据抓得住那个缺陷）")
} else if injection == "cover-controls" {
    check(status != 0, "负对照「注入一个盖住控件列的元素」必须红")
} else {
    check(status == 0, "产品路径：小窗里没有任何元素遮挡控件")
}
print(failureCount == 0
    ? "PASS 小窗无遮挡判据全部通过"
    : "FAIL 小窗无遮挡判据有 \(failureCount) 条不通过")
exit(failureCount == 0 ? 0 : 1)
