// Run from repository root. No app, GPU, network or user settings are opened.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let app = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift"), encoding: .utf8)
let settings = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Settings/GMGNSettingsView.swift"), encoding: .utf8)

func declaration(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{") else {
        print("FAIL: missing production declaration: \(signature)"); exit(1)
    }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("Unbalanced declaration")
}

let store = declaration("final class LivingWorldActivityMenuStore:", in: app)
for required in ["var worldID:", "var activeActivityID:", "var message:", "func canControl("] {
    guard store.contains(required) else { print("FAIL: activity controls missing \(required)"); exit(1) }
}
let navigation = declaration("final class GMGNSettingsNavigation:", in: settings)
let run = declaration("func runLivingWorldActivity(id: String) {", in: app)
let stop = declaration("func stopLivingWorldActivity() {", in: app)
for method in [run, stop] {
    guard method.contains("canControl(worldID: spatialStage.selectedWorldID)"),
          method.contains("menu.report("),
          method.contains("context.manifest.worldID == menu.worldID") else {
        print("FAIL: activity action lacks world binding or user feedback"); exit(1)
    }
}
let openPresence = declaration("func openPresenceSettings()", in: app)
guard openPresence.contains("GMGNSettingsNavigation.shared.page = .presence"),
      openPresence.contains("openSystemSettings()"),
      app.contains("onManageAssets:"), app.contains("onRunActivity:"), app.contains("onStopActivity:"),
      settings.contains("selection: $navigation.page") else {
    print("FAIL: stage callbacks or settings destination disconnected"); exit(1)
}

let harness = #"""
import Foundation
import Combine

struct LifeActivityDefinition { let id: String }
struct LivingWorldActivityMenuItem: Equatable { let id: String }
enum LivingWorldActivityMenuPolicy {
    static func items(definitions: [LifeActivityDefinition]) -> [LivingWorldActivityMenuItem] {
        definitions.map { LivingWorldActivityMenuItem(id: $0.id) }
    }
}
@MainActor
\#(store)
\#(declaration("enum GMGNSettingsPage:", in: settings))
@MainActor
\#(navigation)

@MainActor func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}
MainActor.assumeIsolated {
    let menu = LivingWorldActivityMenuStore()
    check(!menu.canControl(worldID: nil), "uninitialized world disabled")
    menu.update(definitions: [.init(id: "jukebox")], worldID: "cabin")
    check(menu.items.map(\.id) == ["jukebox"], "manifest activities available")
    check(menu.canControl(worldID: "cabin"), "current world enabled")
    check(!menu.canControl(worldID: "other") && !menu.canControl(worldID: nil), "wrong world disabled")
    var changes = 0
    let subscription = menu.objectWillChange.sink { changes += 1 }
    menu.updateActiveActivity(id: "jukebox")
    let afterStart = changes
    menu.updateActiveActivity(id: "jukebox")
    check(changes == afterStart, "world ticks don't republish unchanged activity")
    menu.report("活动不可用")
    check(menu.message == "活动不可用", "failure visible in menu")
    menu.updateActiveActivity(id: nil)
    check(menu.activeActivityID == nil, "stop/completion reflected")
    menu.update(definitions: [], worldID: "other")
    check(menu.message == nil && menu.activeActivityID == nil && menu.items.isEmpty, "new world clears stale state")
    let navigation = GMGNSettingsNavigation()
    navigation.page = .music
    navigation.page = .presence
    check(navigation.page == .presence, "asset destination works for an already-open settings window")
    withExtendedLifetime(subscription) {}
}
print("PASS: activity world binding, current state, feedback and settings navigation")
"""#

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-control-actions-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: temporary) }
let file = temporary.appendingPathComponent("main.swift")
try harness.write(to: file, atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = [file.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
