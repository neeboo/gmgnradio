// 空间优先默认值回归（纯逻辑 + 生产源码合同；无 AppKit/窗口/GPU/权限）。
//
// 覆盖 P1「默认呈现面」（docs/plans/2026-09-27-space-first-plan.md §P1）：
//   1. 电台插件门禁关闭（默认）时三项默认都空间优先：
//        菜单无「打开播放器」、舞台设置面板默认落在「空间」、桌面呈现永不退回光球；
//   2. 门禁打开时三项恢复改动前的行为（代码全部保留，可被打开）；
//   3. 边界：门禁关闭不改变空间自身的可用性——四个面板分区、空间分组、
//      生活活动判定、无角色引导全部照旧，`.orb` / `.openPlayer` / 播放器分区仍在源码里。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")

func read(_ path: String) throws -> String {
    try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
}

func declaration(_ signature: String, in text: String) -> String {
    guard let start = text.range(of: signature)?.lowerBound,
          let opening = text[start...].firstIndex(of: "{") else {
        print("FAIL: missing production behavior \(signature)")
        exit(1)
    }
    var depth = 0
    for index in text[opening...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]) }
    }
    fatalError("unterminated declaration")
}

func occurrences(_ needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

let pluginSource = try read("App/RadioPluginAvailability.swift")
let appSource = try read("App/GMGNRadioApp.swift")
let overlaySource = try read("VisualEngine/StageOverlayView.swift")
let cameraSource = try read("VisualEngine/StageCameraCoordinator.swift")

// 门禁本身 + 三个改动点各自的纯策略，全部从生产源码抽取，避免本地镜像漂移。
let policies = [
    declaration("enum RadioPluginAvailability", in: pluginSource),
    declaration("enum SystemResidentMenuEntry:", in: appSource),
    declaration("enum SystemResidentMenuPolicy", in: appSource),
    declaration("enum StageVisualPickerMode:", in: overlaySource),
    declaration("enum StageControlPanelTab:", in: overlaySource),
    declaration("enum StageVisualPickerGroup:", in: overlaySource),
    declaration("enum StageActivityAvailability", in: overlaySource),
    declaration("enum DesktopPresenceMode:", in: cameraSource),
    declaration("enum LiveCamPresentationRequest:", in: cameraSource),
].joined(separator: "\n")

let gateCall = "isRadioPluginEnabled: RadioPluginAvailability.isEnabled()"

// 生产接线合同：一次性的源码事实，不是本地复刻。
let wiringChecks: [(Bool, String)] = [
    (pluginSource.contains("static let defaultsKey = \"radio.plugin.enabled.v1\""),
     "the gate owns one persisted key"),
    (pluginSource.contains("isEnabled(storedValue: Bool?)")
        && pluginSource.contains("storedValue ?? false"),
     "the gate has an injectable pure entry point whose default is off"),
    (occurrences(gateCall, in: appSource) == 3,
     "menu + both desktop-presence call sites all consult the gate"),
    (occurrences(gateCall, in: overlaySource) == 1,
     "the control panel default consults the gate"),
    (appSource.contains("SystemResidentMenuPolicy.entries("),
     "the menu bar builds its entries through the gated policy"),
    (!appSource.contains(".resolve(snapshot: snapshot)")
        && !appSource.contains(".resolve(snapshot: self.avatarRuntime.snapshot)"),
     "no desktop-presence call site keeps the ungated signature"),
    (overlaySource.contains("tab = .initial(") && !overlaySource.contains(".initial(for: mode)"),
     "the control panel seeds its tab through the gated policy"),
    (appSource.contains("case .openPlayer:")
        && appSource.contains("Button(\"打开播放器\")")
        && appSource.contains("AppMenuAction.showPlayer.perform"),
     "the open-player menu button and its action are retained for the plugin"),
    (appSource.contains("case .toggleDecoration:")
        && appSource.contains("AppMenuAction.toggleDecorationEditor.perform"),
     "the decoration entry is wired through AppMenuAction instead of living in the view"),
    (appSource.contains("orbWindowController?.show()"),
     "the orb presentation path is retained for the plugin"),
    (FileManager.default.fileExists(
        atPath: sources.appendingPathComponent("DesktopPresence/OrbWindowController.swift").path
     ),
     "the orb controller is retained for the plugin"),
    (overlaySource.contains("ForEach(StageControlPanelTab.allCases"),
     "the player panel section stays reachable after the default change"),
]

let harness = #"""
import Foundation

\#(policies)

struct MockAvatar: Equatable {
    let id: String
}

struct StageAvatarRuntimeSnapshot {
    let avatar: MockAvatar?
}

@main struct Main {
    static func main() {
        var checks = 0
        var failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: \(label)") }
        }

        // 0) 门禁默认关闭，且纯入口不读真实 UserDefaults。
        check(RadioPluginAvailability.isEnabled(storedValue: nil) == false,
              "an unset preference means the radio plugin is off")
        check(RadioPluginAvailability.isEnabled(storedValue: false) == false,
              "an explicit false keeps the radio plugin off")
        check(RadioPluginAvailability.isEnabled(storedValue: true) == true,
              "an explicit true opens the radio plugin")
        check(RadioPluginAvailability.defaultsKey == "radio.plugin.enabled.v1",
              "the persisted key is stable")

        let pluginOff = false
        let pluginOn = true
        let noAvatar = StageAvatarRuntimeSnapshot(avatar: nil)
        let withAvatar = StageAvatarRuntimeSnapshot(avatar: MockAvatar(id: "avatar.vrm"))

        // 1) 门禁关闭：三项默认都空间优先。
        check(SystemResidentMenuPolicy.entries(isRadioPluginEnabled: pluginOff)
                == [.showLiveCam, .enterSpace, .toggleDecoration, .settings, .quit],
              "plugin off keeps the menu to space entries plus settings and quit")
        check(!SystemResidentMenuPolicy.entries(isRadioPluginEnabled: pluginOff).contains(.openPlayer),
              "plugin off hides the open-player entry")

        check(StageControlPanelTab.initial(for: .player, isRadioPluginEnabled: pluginOff) == .space,
              "plugin off lands the player entry on the space panel")
        check(StageControlPanelTab.initial(for: .space, isRadioPluginEnabled: pluginOff) == .space,
              "plugin off keeps the space entry on the space panel")

        check(DesktopPresenceMode.resolve(snapshot: noAvatar, isRadioPluginEnabled: pluginOff) != .orb,
              "plugin off never falls back to the orb without an avatar")
        check(DesktopPresenceMode.resolve(snapshot: noAvatar, isRadioPluginEnabled: pluginOff) == .liveCam,
              "plugin off reports the Live Cam surface instead of the orb")
        check(DesktopPresenceMode.resolve(snapshot: withAvatar, isRadioPluginEnabled: pluginOff) == .liveCam,
              "an installed avatar still reports the Live Cam surface")

        // 2) 门禁打开：三项恢复改动前的行为。
        check(SystemResidentMenuPolicy.entries(isRadioPluginEnabled: pluginOn)
                == [.showLiveCam, .enterSpace, .toggleDecoration, .openPlayer, .settings, .quit],
              "plugin on restores the full menu in the original order")
        check(StageControlPanelTab.initial(for: .player, isRadioPluginEnabled: pluginOn) == .player,
              "plugin on restores the player-first panel default")
        check(StageControlPanelTab.initial(for: .space, isRadioPluginEnabled: pluginOn) == .space,
              "plugin on still lands the space entry on the space panel")
        check(DesktopPresenceMode.resolve(snapshot: noAvatar, isRadioPluginEnabled: pluginOn) == .orb,
              "plugin on restores the orb for a no-avatar desktop")
        check(DesktopPresenceMode.resolve(snapshot: withAvatar, isRadioPluginEnabled: pluginOn) == .liveCam,
              "plugin on keeps the Live Cam surface for an installed avatar")

        // 3) 边界：门禁关闭不改变空间功能可用，也不删除任何播放器呈现面。
        check(StageControlPanelTab.allCases == [.player, .space, .motions, .activities],
              "no control panel section was removed")
        check(StageControlPanelTab.allCases.map(\.title) == ["播放器", "空间", "角色", "活动"],
              "panel titles are unchanged")
        check(StageVisualPickerGroup.visibleGroups(for: .space)
                == [.worldSelection, .avatarPlacement, .loadingStatus],
              "space keeps its own settings groups")
        check(StageVisualPickerGroup.visibleGroups(for: .player)
                == [.lyricsEffects, .pointCloud, .particleSize, .musicVideo],
              "the player settings groups are retained for the plugin")
        check(StageActivityAvailability.canRun(isWorldVisible: true,
                                               selectedWorldID: "w",
                                               activityWorldID: "w"),
              "activities still run in a visible matching world")
        check(SystemResidentMenuPolicy.entries(isRadioPluginEnabled: pluginOff).contains(.toggleDecoration)
                && SystemResidentMenuPolicy.entries(isRadioPluginEnabled: pluginOn).contains(.toggleDecoration),
              "the decoration entry exists with the gate off and on: it is not a player entry")
        check(!StageActivityAvailability.canRun(isWorldVisible: false,
                                                selectedWorldID: "w",
                                                activityWorldID: "w"),
              "activity availability is untouched by the plugin gate")
        check(StageActivityAvailability.unavailableMessage(isWorldVisible: false,
                                                           isWorldPresentationRequested: false)
                == "进入空间后可选择生活活动。",
              "space still invites the user to enter when no activity is available")
        check(LiveCamPresentationRequest.resolve(hasAvatar: false)
                == .needsAvatar(guidance: LiveCamPresentationRequest.missingAvatarGuidance),
              "a no-avatar desktop still gets the visible settings guidance")
        check(LiveCamPresentationRequest.resolve(hasAvatar: true) == .present,
              "an installed avatar still presents the Live Cam")

        let status = failures == 0 ? "PASS" : "FAIL"
        print("\(status): \(checks) space-first default checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-space-first-defaults-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let main = temporary.appendingPathComponent("SpaceFirstDefaults.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = temporary.appendingPathComponent("space-first-defaults-test")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-j1", "-swift-version", "6", "-parse-as-library", main.path, "-o", binary.path]
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process()
test.executableURL = binary
try test.run()
test.waitUntilExit()
let testExit = test.terminationStatus

var wiringFailures = 0
for (ok, label) in wiringChecks where !ok {
    wiringFailures += 1
    print("FAIL: \(label)")
}
if wiringFailures > 0 { print("FAIL: \(wiringFailures) space-first wiring checks failed") }
exit(testExit == 0 && wiringFailures == 0 ? 0 : 1)
