@preconcurrency import AVFoundation
import Combine
@preconcurrency import Foundation

private struct StageVideoEndedItem: @unchecked Sendable { let item: AVPlayerItem? }
enum StageVideoPlaybackMode: String, CaseIterable, Codable, Sendable {
    case once, loop, randomSequence
    var displayName: String { switch self { case .once:"单次";case .loop:"循环";case .randomSequence:"随机拼接" } }
    var symbolName: String { switch self { case .once:"play.fill";case .loop:"repeat";case .randomSequence:"shuffle" } }
}
struct StageVideoAsset: Identifiable, Codable, Equatable, Sendable {
    let id: String; let url: URL; let displayName: String; let tags: Set<String>
    init(url: URL) {
        let local=url.standardizedFileURL;self.url=local;id=local.path
        displayName=local.deletingPathExtension().lastPathComponent
        tags=Set(displayName.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}
struct StageBoundVideoPrompt: Identifiable, Equatable, Sendable {
    let trackID: String; let trackTitle: String; let asset: StageVideoAsset
    var id:String { "\(trackID)::\(asset.id)" }
}

/// Rust-confirmed projection plus the AVQueuePlayer executor. There are no
/// preference writes, queue selection, tag ranking or fallback rules here.
@MainActor final class StageVideoPlaybackStore: ObservableObject {
    let player=AVQueuePlayer()
    @Published private(set) var assets:[StageVideoAsset]=[]
    @Published private(set) var mode:StageVideoPlaybackMode = .loop
    @Published private(set) var selectedAssetID:String?
    @Published private(set) var activeAssetID:String?
    @Published private(set) var isActive=false
    @Published private(set) var brightness:Float = 0.68
    @Published private(set) var isUserEnabled=false
    @Published private(set) var pendingBoundVideo:StageBoundVideoPrompt?
    @Published private(set) var authorityError:String?
    @Published private(set) var canRecoverPendingStop=false
    private let executorInstanceID=UUID().uuidString
    private var stoppedActions:Set<String>=[]
    private let authority:RustStageVideoClient?
    private let notificationCenter:NotificationCenter
    private var endObserver:NSObjectProtocol?
    private var looper:AVPlayerLooper?
    private var confirmed:RustStageVideoClient.State?
    private var serial:Task<Void,Never>?
    private var nativeReceipts:[String:Bool]=[:]
    private var itemRecords:[ObjectIdentifier:(RustStageVideoClient.Entry,UInt64)]=[:]
    private var startup:Task<Void,Never>?
    /// Test-only/device boundary injection can prove the authority chain without
    /// invoking AVPlayer.play. Production leaves this nil and uses real player.
    private let suppliedExecutor:(@MainActor (RustStageVideoClient.Action,[StageVideoAsset]) throws -> Bool)?
    private let suppliedStop:(@MainActor () throws -> (queueEmpty:Bool,rateZero:Bool))?

    init(defaults:UserDefaults = .standard,notificationCenter:NotificationCenter = .default,
         authority:RustStageVideoClient? = nil,
         execute: (@MainActor (RustStageVideoClient.Action,[StageVideoAsset]) throws -> Bool)? = nil,
         stopEvidence: (@MainActor () throws -> (queueEmpty:Bool,rateZero:Bool))? = nil) {
        self.authority=authority;self.notificationCenter=notificationCenter;suppliedExecutor=execute
        suppliedStop=stopEvidence
        player.isMuted=true;player.volume=0
        guard let authority else {authorityError="视频业务权威未连接。";return}
        // Native file presence is an observed import fact, never a new writer.
        let imported=(defaults.stringArray(forKey:"stage.video.asset-paths") ?? [])
            .map { StageVideoAsset(url:URL(fileURLWithPath:$0)) }
            .filter { FileManager.default.fileExists(atPath:$0.url.path) }
        let legacy=RustStageVideoClient.Legacy(assets:imported,
            bindings:defaults.dictionary(forKey:"stage.video.track-bindings") as? [String:String] ?? [:],
            selectedAssetID:defaults.string(forKey:"stage.video.selected-asset"),
            enabled:defaults.object(forKey:"stage.video.user-enabled")==nil ? nil:defaults.bool(forKey:"stage.video.user-enabled"),
            mode:defaults.string(forKey:"stage.video.playback-mode"),
            brightness:defaults.object(forKey:"stage.video.brightness")==nil ? nil:Float(defaults.double(forKey:"stage.video.brightness")))
        startup=Task { [weak self] in
            do {
                _=try await authority.read()
                let snapshot=try await authority.importLegacy(legacy)
                self?.project(snapshot)
                if snapshot.state.pendingAction != nil {self?.authorityError="未知视频动作属于先前的原生执行器；当前实例无法核验其停止，请由原宿主核验。"}
            } catch { self?.authorityError=error.localizedDescription }
        }
        endObserver=notificationCenter.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:nil,queue:.main) { [weak self] notification in
            let ended=StageVideoEndedItem(item:notification.object as? AVPlayerItem)
            Task { @MainActor [weak self,ended] in self?.handlePlaybackEnded(ended.item) }
        }
    }
    var selectedAsset:StageVideoAsset? {assets.first { $0.id==selectedAssetID }}
    private func project(_ snapshot:RustStageVideoClient.Snapshot) {
        confirmed=snapshot.state;assets=snapshot.state.assets;mode=snapshot.state.mode
        canRecoverPendingStop=snapshot.state.pendingAction?.executorInstanceID==executorInstanceID
        selectedAssetID=snapshot.state.selectedAssetID;brightness=snapshot.state.brightness
        isUserEnabled=snapshot.state.enabled
        isActive=snapshot.state.playback.active && !snapshot.state.playback.paused
        activeAssetID=snapshot.state.playback.active ? snapshot.state.playback.queue.first?.assetID:nil
        if let p=snapshot.state.pendingBoundVideo,let asset=assets.first(where:{$0.id==p.assetID}) {
            pendingBoundVideo=StageBoundVideoPrompt(trackID:p.trackID,trackTitle:p.trackTitle,asset:asset)
        } else {pendingBoundVideo=nil}
    }
    private func enqueue(_ command:RustStageVideoClient.Command) {
        guard let authority else {authorityError="视频业务权威未连接。";return}
        let predecessor=serial,ready=startup
        serial=Task { [weak self] in
            await predecessor?.value;await ready?.value
            guard let self else {return}
            do {
                // A locally executed action with an uncertain receipt may only
                // retry the receipt. Never execute its queue effect again.
                if let pending=confirmed?.pendingAction,let accepted=nativeReceipts[pending.actionID] {
                    let recovered=try await authority.receipt(pending,accepted:accepted)
                    project(recovered);nativeReceipts.removeValue(forKey:pending.actionID)
                }
                var boundCommand=command;boundCommand.executorInstanceID=executorInstanceID
                let response=try await authority.command(boundCommand)
                project(response)
                guard response.replayed != true,let action=response.state.pendingAction else {
                    authorityError=response.state.pendingAction == nil ? nil:"视频执行状态待核验；未重放旧动作。"
                    return
                }
                let claimed=try await authority.claim(action)
                project(claimed)
                guard claimed.replayed != true,let actual=claimed.state.pendingAction,
                      actual.executionStatus=="claimed" else {throw WorldAuthorityError.invalidResponse}
                let accepted:Bool
                do {accepted=try suppliedExecutor?(actual,assets) ?? executeNative(actual)}
                catch {throw error} // A throw after native mutation is unknown, never a false receipt.
                nativeReceipts[actual.actionID]=accepted
                let finished=try await authority.receipt(actual,accepted:accepted)
                project(finished);nativeReceipts.removeValue(forKey:actual.actionID)
                authorityError=accepted ? nil:"原生视频执行未接受计划。"
            } catch {
                let failure=error.localizedDescription
                // A lost reply may have committed a pending action. Read its
                // identity for explicit stop verification, without claiming or
                // executing it and without hiding the original failure.
                if let current=try? await authority.read() {project(current)}
                authorityError=failure
            }
        }
    }
    func waitForAuthority() async {await startup?.value;await serial?.value}
    /// Only this live executor can verify that its own unknown action stopped.
    /// A new Store instance cannot attest to the previous device's output.
    func recoverPendingByStopping() {
        guard let authority else {authorityError="视频业务权威未连接。";return}
        let predecessor=serial,ready=startup
        serial=Task { [weak self] in
            await predecessor?.value;await ready?.value
            guard let self else {return}
            do {
                let snapshot=try await authority.read();project(snapshot)
                guard let action=snapshot.state.pendingAction else {authorityError=nil;return}
                guard action.executorInstanceID==executorInstanceID else {
                    authorityError="未知视频动作属于先前的原生执行器；当前实例无法核验其停止，请由原宿主核验。";return
                }
                if !stoppedActions.contains(action.actionID) {
                    let evidence:(queueEmpty:Bool,rateZero:Bool)
                    if let suppliedStop {evidence=try suppliedStop()}
                    else {
                        guard suppliedExecutor==nil else {throw WorldAuthorityError.invalidResponse}
                        clearNativeQueue();evidence=(player.items().isEmpty,player.rate==0)
                    }
                    guard evidence.queueEmpty && evidence.rateZero else {throw WorldAuthorityError.invalidResponse}
                    stoppedActions.insert(action.actionID)
                }
                let result=try await authority.command(.init(op:"recoverStopped",actionID:action.actionID,
                    generation:action.generation,executorInstanceID:executorInstanceID,queueEmpty:true,rateZero:true),
                    requestID:"stage-stop-recovery-"+action.actionID)
                project(result);authorityError=nil
            } catch {authorityError=error.localizedDescription}
        }
    }
    func add(_ urls:[URL]) {enqueue(.init(op:"add",assets:urls.filter{$0.isFileURL && $0.pathExtension.lowercased()=="mp4"}.map(StageVideoAsset.init(url:))))}
    func select(_ id:String) {enqueue(.init(op:"select",assetID:id))}
    func toggle(_ id:String) {enqueue(.init(op:"toggle",assetID:id))}
    func remove(_ id:String) {enqueue(.init(op:"remove",assetID:id))}
    func setMode(_ value:StageVideoPlaybackMode) {enqueue(.init(op:"mode",mode:value.rawValue))}
    func setBrightness(_ value:Float) {enqueue(.init(op:"brightness",brightness:value))}
    func apply(_ cue:ProgramVisualCue,trackID:String?=nil,trackTitle:String?=nil) {
        enqueue(.init(op:"cue",trackID:trackID,trackTitle:trackTitle,mood:cue.mood.rawValue,role:cue.role.rawValue))
    }
    func bind(_ id:String,to trackID:String) {enqueue(.init(op:"bind",assetID:id,trackID:trackID))}
    func unbind(trackID:String) {enqueue(.init(op:"unbind",trackID:trackID))}
    func boundAsset(for trackID:String)->StageVideoAsset? {confirmed?.bindings[trackID].flatMap {id in assets.first{$0.id==id}}}
    func playBoundVideo(for trackID:String) {enqueue(.init(op:"playBound",trackID:trackID))}
    func playPendingBoundVideo() {enqueue(.init(op:"playPending"))}
    func dismissBoundVideoPrompt(id:String?=nil) {enqueue(.init(op:"dismiss",promptID:id))}
    func start() {enqueue(.init(op:"start"))}
    func pause() {enqueue(.init(op:"pause"))}
    func resume() {enqueue(.init(op:"resume"))}
    func stop() {enqueue(.init(op:"stop"))}
    func disableByUser() {stop()}
    private func clearNativeQueue() {
        player.pause();looper=nil;player.removeAllItems();itemRecords=[:]
    }
    private func executeNative(_ action:RustStageVideoClient.Action) throws -> Bool {
        switch action.kind {
        case "stop":clearNativeQueue();return player.items().isEmpty
        case "pause":player.pause();return true
        case "resume":guard player.currentItem != nil else{return false};player.play();return true
        case "replace","append":
            let planned=try action.entries.map { entry -> (AVPlayerItem,RustStageVideoClient.Entry) in
                guard let asset=assets.first(where:{$0.id==entry.assetID}),FileManager.default.fileExists(atPath:asset.url.path) else {throw WorldAuthorityError.invalidResponse}
                return (AVPlayerItem(url:asset.url),entry)
            }
            if action.kind=="replace" {clearNativeQueue()}
            if action.mode=="loop",let first=planned.first {
                player.actionAtItemEnd = .advance
                looper=AVPlayerLooper(player:player,templateItem:first.0)
            } else {
                player.actionAtItemEnd = action.mode=="once" ? .pause:.advance
                let generation=action.kind=="append" ? confirmed?.playback.generation ?? 0:action.generation
                for (item,entry) in planned {
                    guard player.canInsert(item,after:player.items().last) else{return false}
                    player.insert(item,after:player.items().last);itemRecords[ObjectIdentifier(item)]=(entry,generation)
                }
            }
            player.play();return player.currentItem != nil
        default:throw WorldAuthorityError.invalidResponse
        }
    }
    private func handlePlaybackEnded(_ item:AVPlayerItem?) {
        guard let item,let record=itemRecords.removeValue(forKey:ObjectIdentifier(item)) else{return}
        enqueue(.init(op:"ended",generation:record.1,entryID:record.0.entryID))
    }
}
