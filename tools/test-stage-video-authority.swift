import Foundation

private final class LostReply: @unchecked Sendable {
    let transport:TaskdHTTPAuthorityClient
    private let lock=NSLock()
    private var method:String?
    private var op:String?
    init(endpoint:String,method:String?=nil,op:String?=nil) {
        transport=TaskdHTTPAuthorityClient(endpointFile:endpoint,helperPath:"/unused",allowsLaunching:false,timeout:5)
        self.method=method;self.op=op
    }
    func call(_ name:String,_ bytes:Data)throws->Data {
        let p=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
        let response=try transport.call(method:name,params:p)
        lock.lock()
        let drop=method==name && (op==nil || op==p["op"] as? String)
        if drop {method=nil;op=nil}
        lock.unlock()
        if drop {throw WorldAuthorityError.unavailable("private fixture lost reply after real commit")}
        return try JSONSerialization.data(withJSONObject:response)
    }
    func dropNext(_ method:String,op:String) {lock.lock();self.method=method;self.op=op;lock.unlock()}
}
@main struct StageVideoAuthorityRegression {
    @MainActor static func main() async throws {
        let endpoint=CommandLine.arguments[1], root=URL(fileURLWithPath:CommandLine.arguments[2])
        var checks=0
        func check(_ value:Bool,_ description:String) {precondition(value,description);checks+=1;print("PASS \(description)")}
        func make(_ scope:String,_ loss:LostReply)->RustStageVideoClient {
            RustStageVideoClient(call:{try loss.call($0,$1)},scope:scope,hostSessionID:"private-stage-host")
        }
        if CommandLine.arguments.count>3 && CommandLine.arguments[3]=="restart" {
            let suite="gmgn-stage-restart-"+UUID().uuidString
            let defaults=UserDefaults(suiteName:suite)!
            defer {defaults.removePersistentDomain(forName:suite)}
            for scope in ["stage-native-fixture","stage-receipt-loss","stage-command-loss","stage-claim-loss"] {
                let transport=LostReply(endpoint:endpoint)
                let client=RustStageVideoClient(call:{try transport.call($0,$1)},scope:scope,hostSessionID:"actual-new-private-host")
                var executions=0
                let restored=StageVideoPlaybackStore(defaults:defaults,authority:client,execute:{_,_ in executions+=1;return true})
                await restored.waitForAuthority()
                check(executions==0,"real daemon restart \(scope) never replays native effects")
                check(restored.assets.count==(scope=="stage-native-fixture" ? 1:2),"real daemon restart \(scope) preserves SQLite catalog rather than new empty defaults")
                if scope=="stage-command-loss" || scope=="stage-claim-loss" {
                    check(restored.authorityError != nil,"real daemon restart \(scope) leaves unresolved execution visible")
                }
            }
            print("PASS \(checks) actual daemon restart production Store checks; no device playback")
            return
        }
        let createdPaths=[root.appendingPathComponent("neon intro.mp4"),root.appendingPathComponent("rain slow.mp4")]
        for path in createdPaths {try Data("raw private file presence fact; device decode not asserted".utf8).write(to:path)}
        let paths=createdPaths.map { StageVideoAsset(url:$0).url }
        let suite="gmgn-stage-video-proof-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        defaults.set(paths.map(\.path),forKey:"stage.video.asset-paths")
        defaults.set(paths[0].path,forKey:"stage.video.selected-asset")
        defaults.set("randomSequence",forKey:"stage.video.playback-mode")
        defaults.set(true,forKey:"stage.video.user-enabled")
        defaults.set(["song":paths[1].path],forKey:"stage.video.track-bindings")
        let before=defaults.dictionaryRepresentation() as NSDictionary
        let client=make("stage-native-fixture",LostReply(endpoint:endpoint))
        var effects:[RustStageVideoClient.Action]=[]
        let store=StageVideoPlaybackStore(defaults:defaults,authority:client,execute:{ action,_ in effects.append(action);return true })
        await store.waitForAuthority()
        check(store.authorityError==nil && store.assets.count==2,"actual production Store imports existing local catalog through HTTP/SQLite")
        check(effects.isEmpty,"initial read/import does not execute a native plan")
        store.start();await store.waitForAuthority()
        check(effects.count==1 && effects[0].entries.count==4,"Rust plans random preloaded slots; controlled device executes once")
        check(zip(effects[0].entries,effects[0].entries.dropFirst()).allSatisfy{$0.0.assetID != $0.1.assetID},"Rust random slots never repeat adjacent assets")
        check(Set(effects[0].entries.map(\.entryID)).count==4,"duplicate video identity still has unique playback entry IDs")
        store.remove(paths[0].path);await store.waitForAuthority()
        if store.assets.count != 1 || store.selectedAssetID != paths[1].path {
            let actual=try await client.read()
            FileHandle.standardError.write(Data("DELETE diagnostic error=\(store.authorityError ?? "none") assets=\(store.assets.map { $0.id }) selected=\(store.selectedAssetID ?? "nil") expected=\(paths[1].path) revision=\(actual.revision) pending=\(actual.state.pendingAction?.kind ?? "none")\n".utf8))
        }
        check(store.assets.count==1 && store.selectedAssetID==paths[1].path,"Rust deletion selects the existing fallback")
        check(effects.count==2 && effects[1].entries.allSatisfy{$0.assetID==paths[1].path},"replacement output consumes Rust fallback only")
        check(store.boundAsset(for:"song")?.id==paths[1].path,"unrelated song binding survives deletion")
        store.stop();await store.waitForAuthority()
        check(!store.isUserEnabled && !store.isActive,"Rust stop permission and actual stop receipt are projected")
        store.apply(ProgramVisualCue(role:.opener,mood:.pulse),trackID:"song",trackTitle:"actual track")
        await store.waitForAuthority()
        check(store.pendingBoundVideo?.asset.id==paths[1].path,"disabled bound video asks through Rust prompt projection")
        store.playPendingBoundVideo();await store.waitForAuthority()
        check(!store.isUserEnabled && store.isActive && effects.last?.mode=="loop","explicit temporary playback preserves global opt-out")
        check(before==defaults.dictionaryRepresentation() as NSDictionary,"production Store never rewrites legacy UserDefaults")
        let persisted=try await client.read()
        check(persisted.state.bindings["song"]==paths[1].path && persisted.state.assets.count==1,"actual SQLite projection owns catalog/binding after native receipt")
        let queue=persisted.state.playback
        do { _=try await client.command(.init(op:"ended",generation:queue.generation+1,entryID:queue.queue.first?.entryID));preconditionFailure("stale generation accepted") }
        catch WorldAuthorityError.daemon("stage_video_stale_receipt") {checks+=1;print("PASS wrong actual playback generation cannot advance queue")}

        let receiptLoss=LostReply(endpoint:endpoint,method:"stage_video_receipt")
        let receiptClient=make("stage-receipt-loss",receiptLoss)
        var receiptEffects=0
        let receiptStore=StageVideoPlaybackStore(defaults:defaults,authority:receiptClient,execute:{_,_ in receiptEffects+=1;return true})
        await receiptStore.waitForAuthority();receiptStore.start();await receiptStore.waitForAuthority()
        check(receiptEffects==1 && receiptStore.authorityError != nil,"real committed receipt lost response preserves uncertain local state")
        receiptStore.setBrightness(0.83);await receiptStore.waitForAuthority()
        check(receiptEffects==1 && receiptStore.authorityError==nil && abs(receiptStore.brightness-0.83)<0.001,"receipt retry uses same body and current journal projection without replaying native output")

        for (scope,method,op) in [("stage-command-loss","stage_video_command","start"),("stage-claim-loss","stage_video_command","claimAction")] {
            let loss=LostReply(endpoint:endpoint,method:method,op:op)
            let actor=make(scope,loss)
            var executions=0
            let first=StageVideoPlaybackStore(defaults:defaults,authority:actor,execute:{_,_ in executions+=1;return true})
            await first.waitForAuthority();first.start();await first.waitForAuthority()
            check(executions==0 && first.authorityError != nil,"\(scope) missing real RPC reply never grants native execution")
            let fresh=make(scope,LostReply(endpoint:endpoint))
            let reopened=StageVideoPlaybackStore(defaults:defaults,authority:fresh,execute:{_,_ in executions+=1;return true})
            await reopened.waitForAuthority()
            check(executions==0 && reopened.authorityError != nil,"\(scope) restart observes unknown pending state without automatic action replay")
            let pending=try await fresh.read()
            check(pending.state.pendingAction?.executionStatus == (op=="start" ? "planned":"claimed"),"\(scope) exact durable claim boundary remains visible")
        }
        let recoveryLoss=LostReply(endpoint:endpoint,method:"stage_video_command",op:"start")
        let recoveryClient=make("stage-stop-recovery",recoveryLoss)
        var stopCount=0
        let recovery=StageVideoPlaybackStore(defaults:defaults,authority:recoveryClient,execute:{_,_ in preconditionFailure("unknown action replayed")},stopEvidence:{stopCount+=1;return(true,true)})
        await recovery.waitForAuthority();recovery.start();await recovery.waitForAuthority()
        check(recovery.canRecoverPendingStop,"unknown command is bound to the actual live executor instance")
        var foreignStops=0
        let foreign=StageVideoPlaybackStore(defaults:defaults,authority:make("stage-stop-recovery",LostReply(endpoint:endpoint)),execute:{_,_ in false},stopEvidence:{foreignStops+=1;return(true,true)})
        await foreign.waitForAuthority();foreign.recoverPendingByStopping();await foreign.waitForAuthority()
        check(foreignStops==0 && foreign.authorityError != nil,"same host string with a new executor cannot attest old device stop")
        recoveryLoss.dropNext("stage_video_command",op:"recoverStopped")
        recovery.recoverPendingByStopping();await recovery.waitForAuthority()
        check(stopCount==1 && recovery.authorityError != nil,"actual native stop precedes Rust confirmation and a lost reply stays visible")
        recovery.recoverPendingByStopping();await recovery.waitForAuthority()
        check(stopCount==1 && recovery.authorityError==nil && !recovery.isActive,"retry confirms durable stopped state without a second native stop")
        check((try await recoveryClient.read()).state.pendingAction==nil,"only real stop confirmation clears original unknown action")
        let fresh=make("stage-native-fixture",LostReply(endpoint:endpoint))
        var reopenedEffects=0
        let reopened=StageVideoPlaybackStore(defaults:defaults,authority:fresh,execute:{_,_ in reopenedEffects+=1;return true})
        await reopened.waitForAuthority()
        check(reopenedEffects==0 && reopened.assets.count==1,"fresh consumer restores live catalog and never replays old player command")
        print("PASS \(checks) real HTTP/SQLite→production Swift Store checks; controlled native receipts, no AVPlayer.play/GUI/audio")
    }
}
