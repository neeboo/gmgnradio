// App wiring checks; generation and resident scheduling have separate behavioural fixtures.
import Foundation
let app = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", encoding: .utf8)
let settings = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/Settings/GMGNSettingsView.swift", encoding: .utf8)
var checks = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    guard condition else { print("FAIL: \(message)"); exit(1) }
}
check(app.contains("private func refreshWishMachine() async"), "existing host timer must integrate wish-machine tasks")
check(app.contains("await refreshWishMachine()"), "existing timer must invoke bounded task refresh")
check(app.contains("await wishMachineCoordinator.refreshPending(limit: 2)"), "task status refresh has a bounded per-tick limit")
check(app.contains("ResidentWishMachineTools(coordinator:"), "resident must receive formal generation and claim tools")
check(app.contains("authorizationID: input.runID"), "generation grant belongs to the actual human turn")
check(app.contains("!input.isBackground") && app.contains("registered.loopID == ObjectIdentifier(loop)"), "background or different-loop images cannot acquire a generation grant")
check(app.contains("loop.receiveContinuationEvent(observation)"), "verified output completion must be a delegated continuation event")
check(app.contains("spatialStage.wishMachineOutputStatus == .ready(id: event.objectID)"), "no ready notification before the matching mesh is rendered")
check(app.contains("acknowledgeWishEvents(input.events"), "durable completion is acknowledged only from a consumed resident turn")
check(app.contains("PropGenerationConfigurationStore(") && app.contains("PropGenerationConfigurationStore.defaultFileURL\n            ).load()") && app.contains("propGenerationStore.clearConfiguration()"), "missing or invalid configuration must remove the old in-memory credentials")
check(settings.contains("PropGenerationSettingsSection()"), "space settings must expose service configuration")
check(app.contains("synchronizeOwnedResidentProps()") && app.contains("read_owned_props 核对入库"), "claim hands the verified asset to durable inventory before support-surface placement")
check(app.contains("onUserStop: { [weak self] in Task { @MainActor in await self?.pauseResidentWishContinuations() } }"),
      "only an explicit user stop persists the durable automatic pickup pause")
check(app.components(separatedBy: "pauseResidentWishContinuations").count == 3,
      "the task-level pause has exactly one wiring site (its definition plus the user-stop callback) and never hangs off the generic cancellation channel")
check(app.contains("wishMachineCoordinator.automaticContinuationEvents("), "automatic pickup only consumes unpaused durable events")
check(app.contains("allowsPausedWishClaim: !input.isBackground"), "only human turns can manually claim previously paused jobs")
check(app.contains("continuationResumeAuthorizationID: allowsPausedWishClaim ? messageID : nil"), "restoring a wish receives a fresh foreground turn identity, never a background grant")
check(app.contains("resumePlacementStatus:") && app.contains("placedState.generatedProp != nil") && app.contains("return placedState.isEnabled"), "resuming a claimed wish reads actual owned world state to prevent duplicate placement")
check(app.contains("UUID(uuidString: placedState.generatedProp?.sourceWishID ?? \"\") == job.id"), "resume readback validates the generated prop belongs to the same wish")
check(app.contains("resume_wish_continuation") && app.contains("仅更新居民意图不会恢复许愿授权"), "prompt distinguishes wish authorization restoration from loop intent restoration")
// 系统提示词里的手持上限必须与判据**同源**：这里钉的是**插值位**，不是数字 ——
// 提示词里写死任何一个数（哪怕恰好等于上限）都会红，因为上限改了它不会跟着改。
check(app.contains("正式领取且最长边不超过 \\(ResidentPropAttachmentEligibility.holdableLongestEdgeText)的小道具"), "resident prompt must describe the actual hand-held size boundary by interpolating the single limit definition")
check(!app.contains("45 厘米"), "resident prompt must not hardcode a second copy of the hand-held size boundary")
// 挂点（手 / 背后 / 腰间）落地后提示词的措辞变了：这里钉的是**它必须说的东西**
// （已适配的角色 + 支持的挂点），不是某一句固定措辞 —— 措辞再改也不该让它变成
// "红着没人管"，但少说一个挂点就会红。
check(app.contains("当前已适配的 2B") && ["右手", "背后", "腰间"].allSatisfy { app.contains($0) }, "resident prompt must identify the currently supported avatar and every supported slot")
check(app.contains("hold_prop、adjust_held_prop_grip、return_held_prop"), "resident prompt must direct the agent to formal held-prop tools")
check(!app.contains("没有冲泡、战斗或手持功能"), "resident prompt must not deny the implemented hand-held capability")
print("PASS: \(checks) wish-machine App wiring checks (no host launch)")
