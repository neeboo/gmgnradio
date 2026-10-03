// 领取就绪 / 实际入库 / 承托层加载 / 重启已读恢复的**接线**门禁（2026-10-03 E2E 拒收项）。
//
// 上一轮真实 E2E（`/tmp/gmgn-e2e-20261003-1710`）的三条硬失败：
//   · 驱动器把 `generated`（服务已生成、**待下载检查**）当就绪，claim 必然 `notReady`；
//   · claim 后 `read_owned_props.objects=[]`、`list_placement_surfaces.surfaces=[]`
//     —— 领取/入库是异步的，驱动器读一次空列表；而承托几何过去只在**装修面板打开**
//     时才派生，agent 关着面板永远拿不到承托层；
//   · 重启后立刻读收件箱（内存空表）⇒ "记录丢了、未读 0" 被误当成持久化失败。
//
// 这个 harness 做**来源扫描**（App / 摆放几何模型原文）+ 两条注入负对照：
// 把"恢复先于读取"或"面板无关的承托几何"标记删掉后，同一判据必须红。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func read(_ relative: String) -> String? {
    try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
}

var failures = 0
var checks = 0
func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}

guard let app = read("apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift"),
      let model = read("apps/macos/Sources/GMGNRadio/Presence/ResidentPropGridEditorModel.swift")
else {
    print("FAIL: 找不到 claim/restart 接线要扫描的生产源码")
    exit(1)
}

// MARK: - 来源扫描：App 侧

/// 每一条都是"少了它，上一轮的真实失败就会原样复发"的最小接线点。
let appMarkers = [
    // 收件箱：先恢复持久层再投影；`restored` 如实说明这一步发生过。
    "private func e2eInboxState() async -> [String: Any]",
    "await residentSystemInboxStore.restore(worldID: worldID, residentScope: world.sessionScope)",
    "\"restored\": true",
    // 领取就绪：状态快照暴露相位、托盘现场推导、逐任务的领取门与本地模型证据。
    "\"activityPhase\"",
    "\"claimReady\"",
    "\"claimError\"",
    "\"modelFileExists\"",
    "\"wishMachineOutputStatus\"",
    "\"placementSupportReady\"",
    // 承托几何与装修面板解耦：世界加载后备好、摆放服务从保留位读。
    "private func prepareResidentPlacementSupport(context: WorldAgentContext)",
    "prepareResidentPlacementSupport(context: context)",
    "supportForPlacement(key: context.manifest.worldID)",
]

for marker in appMarkers where !app.contains(marker) {
    print("FAIL: App 缺少 claim/restart 接线：\(marker)")
    failures += 1
}
checks += appMarkers.count

// MARK: - 来源扫描：承托几何模型

let modelMarkers = [
    // 保留位与在飞的派生分开记账：网格与碰撞世界只在装填时一起写。
    "func preparePlacementSupport(",
    "func supportForPlacement(key: String)",
    "guard placementGridKey == key",
    "placementGrid = built.grid",
    "placementCollision = collision",
    // 摆放用的移动图也必须读保留位（否则关着面板时 routeConstraint 仍为 nil）。
    "guard let grid = placementGrid ?? grid, let routeBand else { return nil }",
]

for marker in modelMarkers where !model.contains(marker) {
    print("FAIL: 摆放几何模型缺少面板无关的承托加载：\(marker)")
    failures += 1
}
checks += modelMarkers.count

// MARK: - 注入负对照

func missingMarkers(in source: String, among markers: [String]) -> [String] {
    markers.filter { !source.contains($0) }
}

// 负对照①：把"恢复先于读取"删掉（回到重启后读内存空表）⇒ 必须红。
let inboxMarkers = ["await residentSystemInboxStore.restore(worldID: worldID, residentScope: world.sessionScope)"]
let withoutRestore = app.replacingOccurrences(of: inboxMarkers[0], with: "")
guard missingMarkers(in: withoutRestore, among: inboxMarkers).count == 1 else {
    print("FAIL: 负对照①注入失败（收件箱恢复标记不唯一）；门禁失效")
    exit(1)
}
check(missingMarkers(in: withoutRestore, among: inboxMarkers).count == 1,
      "注入负对照①：删掉收件箱恢复必须让判据变红")

// 负对照②：把"摆放服务从保留位读"删掉（回到只读装修会话的 grid）⇒ 必须红。
let supportMarkers = ["supportForPlacement(key: context.manifest.worldID)"]
let withoutPlacementRead = app.replacingOccurrences(of: supportMarkers[0], with: "")
guard missingMarkers(in: withoutPlacementRead, among: supportMarkers).count == 1 else {
    print("FAIL: 负对照②注入失败（承托保留位读取标记不唯一）；门禁失效")
    exit(1)
}
check(missingMarkers(in: withoutPlacementRead, among: supportMarkers).count == 1,
      "注入负对照②：删掉承托保留位读取必须让判据变红")

print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) claim/restart wiring checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
