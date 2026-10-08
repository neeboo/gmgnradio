import Foundation

// Executes production native projection/mutation methods with a gated authority
// double. This does not stand in for the separate taskd SQL/HTTP acceptance.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let visual = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/VisualEngine/StageVisualPresetTimeline.swift"), encoding: .utf8)
let spatial = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/VisualEngine/SpatialStageStore.swift"), encoding: .utf8)
func slice(_ text: String, _ from: String, _ to: String) -> String {
    let start = text.range(of: from)!.lowerBound
    let end = text.range(of: to, range: start..<text.endIndex)!.lowerBound
    return String(text[start..<end])
}
let visualClass = slice(visual, "@MainActor\nfinal class StageVisualDirectionStore", "\nstruct StageVisualPresetTimeline")
let mutations = slice(spatial, "    func setAvatarPosition(", "    /// Applies a world-space offset")
let projection = slice(spatial, "    private func installBaseAvatarPlacement(", "    func setWorldVisible(")
precondition(!visualClass.contains("defaults.set") && !mutations.contains("defaults.") && !projection.contains("defaults."))
let header = #"""
import Foundation
import Combine
enum StagePointCloudChoice: String { case automatic, galaxyField }
enum StageVisualMood {case neutral}
struct StageVisualPalette { static func forMood(_ mood:StageVisualMood)->Self {Self()} }
struct ProgramVisualCue {let mood:StageVisualMood;let palette:StageVisualPalette;let intensity:Float;let transitionDuration:TimeInterval}
enum SpatialAvatarPositionAxis:String {case x="X",y="Y",z="Z"}
enum Scene:String {case djHouse}
struct StageAvatarPlacement {let position:SIMD3<Float>;let scale:Float;let yaw:Float}
@MainActor final class RustProductSettingsClient {
    struct Values {var avatarPositions:[String:[Double]]=[:];var stagePointCloudChoice="automatic";var stageParticleSizeMultiplier=1.0}
    struct Snapshot {var values:Values}
    enum Failure:Error {case rejected}
    static let shared=RustProductSettingsClient()
    static func stageLegacySnapshot(_ defaults:UserDefaults)->[String:Any] {defaults.dictionaryRepresentation()}
    var confirmed:Snapshot?=Snapshot(values:Values())
    var gate:CheckedContinuation<Void,Never>?
    var rejecting=false
    func wait() async throws {await withCheckedContinuation {gate=$0};if rejecting {throw Failure.rejected}}
    func release() {gate?.resume();gate=nil}
    func importStageLegacy(legacy:[String:Any]) async throws ->Snapshot {confirmed!}
    func selectPointCloud(raw:String) async throws ->Snapshot {try await wait();confirmed!.values.stagePointCloudChoice=raw;return confirmed!}
    func setParticleSizeMultiplier(_ raw:Double) async throws ->Snapshot {try await wait();confirmed!.values.stageParticleSizeMultiplier=1.6;return confirmed!}
    func setAvatarPosition(scope:String,axis:String,value:Double,basePosition:[Double]) async throws ->Snapshot {
        try await wait();var xyz=confirmed!.values.avatarPositions[scope] ?? basePosition
        xyz[axis == "X" ? 0 : axis == "Y" ? 1 : 2]=value;confirmed!.values.avatarPositions[scope]=xyz;return confirmed!
    }
    func resetAvatarPosition(scope:String) async throws ->Snapshot {try await wait();confirmed!.values.avatarPositions[scope]=nil;return confirmed!}
}
@MainActor final class SpatialStageStore {
    let settings:RustProductSettingsClient
    var settingsError:String?
    var selectedWorldID:String?="first"
    var selectedScene=Scene.djHouse
    var baseAvatarPlacement=StageAvatarPlacement(position:SIMD3(0.1,-0.09,-0.75),scale:1,yaw:0)
    var stableAvatarPlacement=StageAvatarPlacement(position:SIMD3(0.1,-0.09,-0.75),scale:1,yaw:0)
    var avatarPlacement=StageAvatarPlacement(position:SIMD3(0.1,-0.09,-0.75),scale:1,yaw:0)
    var transientAvatarPlacement:StageAvatarPlacement?
    init(settings:RustProductSettingsClient){self.settings=settings}
    func awaitSettingsReady() async throws {}
"""#
let tests = #"""
}
@main struct Check {
    @MainActor static func main() async throws {
        let suite="ai.gmgn.private.stageprojection."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        defaults.set("old-value",forKey:"stage.point-cloud-choice")
        let prior=defaults.dictionaryRepresentation()
        let authority=RustProductSettingsClient()
        let visual=StageVisualDirectionStore(defaults:defaults,settings:authority)
        for _ in 0..<5 {await Task.yield()}
        let cloud=Task {try await visual.selectPointCloud(rawValue:"galaxyField")}
        while authority.gate == nil {await Task.yield()}
        precondition(visual.currentPointCloudChoice == .automatic)
        authority.release();try await cloud.value
        precondition(visual.currentPointCloudChoice == .galaxyField)
        authority.rejecting=true
        let rejected=Task {try await visual.selectPointCloud(rawValue:"automatic")}
        while authority.gate == nil {await Task.yield()}
        authority.release()
        do {try await rejected.value;fatalError("rejection promoted") }catch{}
        precondition(visual.currentPointCloudChoice == .galaxyField)
        authority.rejecting=false
        let particles=Task {try await visual.setParticleSizeMultiplier(rawValue:99)}
        while authority.gate == nil {await Task.yield()}
        precondition(visual.particleSizeMultiplier == 1)
        authority.release();try await particles.value
        precondition(visual.particleSizeMultiplier == 1.6)
        let stage=SpatialStageStore(settings:authority)
        let axis=Task {try await stage.setAvatarPosition(rawValue:0.4,axis:"X")}
        while authority.gate == nil {await Task.yield()}
        precondition(stage.avatarPlacement.position.x == 0.1)
        authority.release();try await axis.value
        precondition(stage.avatarPlacement.position == SIMD3(0.4,-0.09,-0.75))
        let reset=Task {try await stage.resetAvatarPositionConfirmed()}
        while authority.gate == nil {await Task.yield()}
        authority.release();try await reset.value
        precondition(stage.avatarPlacement.position == stage.baseAvatarPlacement.position)
        let stale=Task {try await stage.setAvatarPosition(rawValue:0.8,axis:"X")}
        while authority.gate == nil {await Task.yield()}
        stage.selectedWorldID="second"
        authority.release();try await stale.value
        precondition(stage.avatarPlacement.position == stage.baseAvatarPlacement.position)
        precondition(authority.confirmed!.values.avatarPositions["world.first"]![0] == 0.8)
        precondition(NSDictionary(dictionary:prior).isEqual(to:defaults.dictionaryRepresentation()))
        print("PASS production native projection: await/rejection/confirmed clamp/base/reset/scope fencing/no defaults writes; SQL acceptance separate")
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-stage-projection-"+UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
defer {try? FileManager.default.removeItem(at:temporary)}
let source = temporary.appendingPathComponent("check.swift")
try (header + "\n" + mutations + projection + tests + "\n" + visualClass).write(to:source,atomically:true,encoding:.utf8)
let compiler=Process();compiler.executableURL=URL(fileURLWithPath:"/usr/bin/swiftc")
let binary=temporary.appendingPathComponent("check")
compiler.arguments=["-swift-version","6","-parse-as-library",source.path,"-o",binary.path]
try compiler.run();compiler.waitUntilExit();guard compiler.terminationStatus == 0 else {exit(compiler.terminationStatus)}
let check=Process();check.executableURL=binary;try check.run();check.waitUntilExit();exit(check.terminationStatus)
