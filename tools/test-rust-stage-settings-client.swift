import Foundation
import Combine
import CryptoKit

// Only DTO/platform leaves surrounding the extracted production consumer methods.
enum StagePointCloudChoice: String { case automatic, flowingCanvas, orbitalShell, openRibbon, vinylRecord, galaxyField, tunnel, void }
enum StageVisualMood { case neutral }
struct StageVisualPalette { static func forMood(_ mood: StageVisualMood) -> Self { Self() } }
struct ProgramVisualCue { let mood: StageVisualMood; let palette: StageVisualPalette; let intensity: Float; let transitionDuration: TimeInterval }
enum SpatialAvatarPositionAxis: String { case x="X", y="Y", z="Z" }
enum FixtureScene: String { case djHouse="dj_house", cosyWoodHouse="cosy_wood_house" }
struct StageAvatarPlacement { let position: SIMD3<Float>; let scale: Float; let yaw: Float }
struct MusicLyrics { let text: String }
struct StageLyricLine {}
struct StageAITheme {}
struct StageLyricsParser { func parse(_ lyrics: MusicLyrics, trackDuration: TimeInterval?) -> [StageLyricLine] { [] } }

final class StageFaultTransport: @unchecked Sendable {
    let wire: RustProductSettingsClient.Call
    private let condition=NSCondition()
    private var blocked=false, waiting=false, loss=false
    private var captured: (String,Data)?
    private var writeCount=0
    init(wire: @escaping RustProductSettingsClient.Call) { self.wire=wire }
    func gateNext() { condition.lock(); blocked=true; condition.unlock() }
    func isWaiting() -> Bool { condition.lock(); defer {condition.unlock()}; return waiting }
    func release() { condition.lock(); blocked=false; condition.broadcast(); condition.unlock() }
    func loseNextReceipt() { condition.lock(); loss=true; condition.unlock() }
    func count() -> Int { condition.lock(); defer {condition.unlock()}; return writeCount }
    func lostRequest() -> (String,Data) { condition.lock(); defer {condition.unlock()}; return captured! }
    func call(_ method: String, _ data: Data) throws -> Data {
        condition.lock()
        let stageWrite=method == "product_settings_stage_event"
        if stageWrite {
            writeCount += 1; waiting=true
            while blocked { condition.wait() }
            waiting=false
        }
        let lose=stageWrite && loss; if lose { loss=false; captured=(method,data) }
        condition.unlock()
        let response: Data
        do { response=try wire(method,data) }
        catch { FileHandle.standardError.write(Data("RPC FAILED \(method): \(error)\n".utf8)); throw error }
        if lose { throw RustProductSettingsClient.SettingsError.unavailable }
        return response
    }
}

@main struct StageSettingsAcceptance {
    @MainActor static func main() async throws {
        precondition(CommandLine.arguments.count == 4)
        let endpoint=CommandLine.arguments[1], mode=CommandLine.arguments[2]
        let transport=TaskdHTTPAuthorityClient(endpointFile:endpoint,helperPath:"",allowsLaunching:false,timeout:5)
        let wire: RustProductSettingsClient.Call = { method,data in
            let value=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            let digest=SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
            let normalized=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
            let normalizedDigest=SHA256.hash(data:normalized).map { String(format:"%02x",$0) }.joined()
            let event=value["event"] as? [String:Any]
            FileHandle.standardError.write(Data("WIRE mode=\(mode) method=\(method) requestID=\(value["requestID"] ?? "none") revision=\(value["expectedRevision"] ?? "none") kind=\(event?["kind"] ?? "none") bytes=\(data.count) sha=\(digest) normalizedSHA=\(normalizedDigest)\n".utf8))
            return try JSONSerialization.data(withJSONObject:transport.call(method:method,params:value))
        }
        let fault=StageFaultTransport(wire:wire)
        let settings=RustProductSettingsClient(call:fault.call)
        if mode == "reopen" {
            try await settings.reload()
            precondition(settings.confirmed!.values.stagePointCloudChoice == "galaxyField")
            precondition(settings.confirmed!.values.stageLyricsMode == "automatic")
            precondition(settings.confirmed!.values.stageLyricsTrackID == "track-d")
            precondition(settings.confirmed!.values.stageLyricsResolvedMode == "article")
            precondition(settings.confirmed!.values.stageParticleSizeMultiplier == 1.6)
            precondition(settings.confirmed!.values.avatarPositions["world.private-world"] == nil)
            print("PASS new process actual SQLite reopen: stage/cloud/particle/lyrics persisted, no mutation replay")
            return
        }
        let suite="ai.gmgn.private.stagesettings."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set("ja",forKey:"unity.ui.locale")
        defaults.set("private legacy persona",forKey:"resident.persona.v1")
        defaults.set([0.2,0.3,-0.7],forKey:"ai.gmgn.radio.spatial.avatar-position.world.private-world")
        defaults.set("tunnel",forKey:"stage.point-cloud-choice")
        defaults.set(0.8,forKey:"stage.particle-size-multiplier")
        defaults.set("monet_poster",forKey:"stage.lyrics.visualMode")
        let legacy=defaults.dictionaryRepresentation()
        if mode == "global-first" { settings.bootstrap(legacy:RustProductSettingsClient.legacySnapshot(defaults)); try await settings.ensureLoaded() }
        let visual=StageVisualDirectionStore(defaults:defaults,settings:settings)
        try await visual.awaitSettingsReady()
        if mode == "stage-first" { settings.bootstrap(legacy:RustProductSettingsClient.legacySnapshot(defaults)); try await settings.ensureLoaded() }
        precondition(settings.confirmed!.values.locale == "ja", "stage-first must not suppress global import")
        precondition(settings.confirmed!.values.residentPersona == "private legacy persona")
        precondition(visual.currentPointCloudChoice == .tunnel)
        precondition(abs(visual.particleSizeMultiplier-0.8)<0.0001)
        let lyrics=StageLyricsStore(defaults:defaults,settings:settings)
        try await lyrics.waitForAuthority()
        precondition(lyrics.visualMode == .posterRail)
        lyrics.publish(MusicLyrics(text:"private fixture"),trackID:"track-c")
        try await lyrics.waitForAuthority()
        precondition(lyrics.resolvedVisualMode == .posterRail)
        try await lyrics.cycleVisualMode()
        precondition(lyrics.visualMode == .editorialField, "cycle preserves allCases, not automatic playback order")
        try await lyrics.setVisualMode(rawValue:"automatic")
        precondition(lyrics.resolvedVisualMode == .cloudSteps)
        lyrics.publish(MusicLyrics(text:"private fixture"),trackID:"track-d")
        try await lyrics.waitForAuthority()
        precondition(lyrics.resolvedVisualMode == .editorialField)
        do { try await lyrics.setVisualMode(rawValue:"invalid"); fatalError("invalid lyrics accepted") } catch WorldAuthorityError.daemon(let code) { precondition(code=="product_settings_invalid_value") }
        precondition(lyrics.visualMode == .automatic)
        let stage=SpatialStageStore(settings:settings)
        stage.installAvatarPlacement(StageAvatarPlacement(position:SIMD3(0.1,-0.09,-0.75),scale:1,yaw:0))
        precondition(stage.avatarPlacement.position == SIMD3(0.2,0.3,-0.7))
        fault.gateNext()
        let axis=Task { try await stage.setAvatarPosition(rawValue:0.4,axis:"x") }
        while !fault.isWaiting() { await Task.yield() }
        precondition(stage.avatarPlacement.position == SIMD3(0.2,0.3,-0.7))
        fault.release(); try await axis.value
        precondition(stage.avatarPlacement.position == SIMD3(0.4,0.3,-0.7))
        do { try await stage.setAvatarPosition(rawValue:2.001,axis:"X"); fatalError("range accepted") } catch WorldAuthorityError.daemon(let code) { precondition(code=="product_settings_invalid_value") }
        precondition(stage.avatarPlacement.position.x == 0.4)
        try await stage.resetAvatarPositionConfirmed()
        precondition(stage.avatarPlacement.position == stage.baseAvatarPlacement.position)
        try await visual.setParticleSizeMultiplier(rawValue:99)
        precondition(abs(visual.particleSizeMultiplier-1.6)<0.0001)
        fault.gateNext(); let cloud=Task { try await visual.selectPointCloud(rawValue:"void") }
        while !fault.isWaiting() { await Task.yield() }
        precondition(visual.currentPointCloudChoice == .tunnel)
        fault.release(); try await cloud.value
        precondition(visual.currentPointCloudChoice == .void)
        fault.loseNextReceipt(); let count=fault.count()
        do { try await visual.selectPointCloud(rawValue:"galaxyField"); fatalError("lost receipt promoted") } catch RustProductSettingsClient.SettingsError.unavailable {}
        precondition(visual.currentPointCloudChoice == .void)
        precondition(settings.confirmed!.values.stagePointCloudChoice == "void")
        precondition(fault.count()==count+1)
        // Authority readback may recover; no second command is issued.
        try await settings.reload()
        precondition(visual.currentPointCloudChoice == .galaxyField)
        let lost=fault.lostRequest(), revision=settings.confirmed!.revision
        FileHandle.standardError.write(Data("PHASE exact lost receipt replay\n".utf8))
        _ = try await Task.detached { try wire(lost.0,lost.1) }.value
        try await settings.reload(); precondition(settings.confirmed!.revision==revision)
        do { try await visual.selectPointCloud(rawValue:"bad"); fatalError("bad cloud accepted") } catch WorldAuthorityError.daemon(let code) { precondition(code=="product_settings_invalid_value") }
        precondition(visual.currentPointCloudChoice == .galaxyField)
        precondition(NSDictionary(dictionary:legacy).isEqual(to:defaults.dictionaryRepresentation()), "native consumers must not write legacy keys")
        try Data("seeded".utf8).write(to:URL(fileURLWithPath:CommandLine.arguments[3]))
        print("PASS actual typed client + extracted production native consumers: \(mode), readonly keys, gated/lost receipts, axis/reset, clamp, lyrics cycle/hash")
    }
}
