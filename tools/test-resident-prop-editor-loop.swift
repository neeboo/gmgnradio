// Actual loop cancellation + extracted host pause boundary. No model, host or user files.
import Foundation
let source=try String(contentsOfFile:"apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift",encoding:.utf8)
func declaration(_ signature:String)->String {
    let start=source.range(of:signature)!.lowerBound,open=source[start...].firstIndex(of:"{")!
    var depth=0
    for index in source[open...].indices {if source[index] == "{" {depth += 1};if source[index] == "}" {depth -= 1};if depth == 0{return String(source[start...index])}}
    fatalError("declaration")
}
let methods=["private func temporarilyPauseResidentForPropEditing()","private func pauseResidentWishContinuations()","private struct ResidentWishScope"].map(declaration).joined(separator:"\n")
// 接线守卫：任务级**持久、只能人工解除**的暂停只允许挂在"用户停止"这条回调上。
// 旧代码把它挂在通用取消通道 `onCancel` 上，于是换空间/退出/自主可用性回收/网络回收
// 都会写出一条暂停，用户从没按过停止却要手动点「恢复自动领取」。把这条接线退回去，
// 下面两条断言（以及这里）就会 FAIL。
let cancelClosure = source.contains("onCancel: { [weak self] in") ? declaration("onCancel: { [weak self] in") : ""
let userStopClosure = source.contains("onUserStop: { [weak self] in") ? declaration("onUserStop: { [weak self] in") : ""
guard !cancelClosure.contains("pauseResidentWishContinuations()"),
      userStopClosure.contains("pauseResidentWishContinuations()") else {
    print("FAIL: the task-level wish pause must hang off the explicit user-stop callback, never the generic cancellation channel")
    exit(1)
}
let harness = #"""
import Foundation
@MainActor final class PrivateStateTransport:ResidentStateTransport {
    let rpc:PrivateRPC
    init(_ rpc:PrivateRPC) {self.rpc=rpc}
    func call(method:String,params:[String:ResidentStateJSON]) async throws -> [String:ResidentStateJSON] {
        let bytes=try JSONEncoder().encode(params),rpc=self.rpc
        let data=try await Task.detached {try rpc.call(method,bytes)}.value
        return try JSONDecoder().decode([String:ResidentStateJSON].self,from:data)
    }
}
@MainActor final class Coordinator {
    var pauses=0
    let rpc:PrivateRPC
    init(_ rpc:PrivateRPC) {self.rpc=rpc}
    func pauseContinuations(worldID:String,residentScope:String) async throws {
        let bytes=try JSONSerialization.data(withJSONObject:["scope":["worldID":worldID,"residentScope":residentScope],"action":"userStop","requestID":UUID().uuidString])
        let rpc=self.rpc
        _ = try await Task.detached {try rpc.call("resident_intent_pause",bytes)}.value
        pauses += 1
    }
}
@MainActor final class App {
    var residentPropTemporaryCancellation=false
    var residentAgentLoop:ResidentAgentLoop?
    let wishMachineCoordinator:Coordinator
    let rpc:PrivateRPC
    let scheduler:RustResidentSchedulerClient
    let memory:ResidentMemoryStore
    var cancelledInvocations=0
    init(_ rpc:PrivateRPC) {
        self.rpc=rpc;wishMachineCoordinator=Coordinator(rpc)
        scheduler=RustResidentSchedulerClient(worldID:"room",residentScope:"resident",hostSessionID:"fixture-host",call:rpc.call)
        memory=ResidentMemoryStore(client:ResidentStateClient(transport:PrivateStateTransport(rpc)))
    }
    private var residentWishScope:ResidentWishScope?
    var runs=0
    var now=Date(timeIntervalSince1970:100)
    func showResidentVoiceStatus(_ message:String) { }
    \#(methods)
    func prepare() {
        let loop=ResidentAgentLoop(now:{[weak self] in self?.now ?? Date()},configuration:.init(minimumWakeInterval:1),run:{[weak self] input in
            guard let self,let binding=self.residentAgentLoop?.claimedRustBinding(runID:input.runID) else {preconditionFailure("invocation started without real durable claim")}
            let state=try await self.readScheduler()
            precondition((state["events"] as! [[String:Any]]).contains { $0["runID"] as? String == input.runID.uuidString && $0["hostSessionID"] as? String == "fixture-host" && $0["state"] as? String == "claimed" },"claim must be persisted before execution")
            self.runs += 1
            do {try await Task.sleep(for:.seconds(30));return "done"}
            catch is CancellationError {
                // This fixture owns exactly this sleep invocation and has no
                // external side effects. Its actual return proves termination.
                _ = try await binding.scheduler.finish(binding.ticket,outcome:"cancelled",invocationStarted:true,cancellationConfirmed:true)
                self.cancelledInvocations += 1
                throw CancellationError()
            }
        },steer:{_ in .notDelivered},onReply:{_ in},onFailure:{_ in},onChange:{},onCancel:{},onUserStop:{[weak self] in Task {await self?.pauseResidentWishContinuations()}},rustScheduler:scheduler,rustSchedulerAvailability:{true})
        residentAgentLoop=loop
        loop.bindMemory(store:memory,scope:.init(worldID:"room",residentScope:"resident"))
        residentWishScope=ResidentWishScope(loopID:ObjectIdentifier(loop),worldID:"room",residentScope:"resident")
    }
    func beginEditing() { temporarilyPauseResidentForPropEditing() }
    func readScheduler() async throws -> [String:Any] {
        let bytes=try JSONSerialization.data(withJSONObject:["worldID":"room","residentScope":"resident"]),rpc=self.rpc
        let reply=try await Task.detached {try rpc.call("agent_loop_read",bytes)}.value
        return try JSONSerialization.jsonObject(with:reply) as! [String:Any]
    }
}
@main struct Tests {
    @MainActor static func main() async throws {
        let app=App(try PrivateRPC(CommandLine.arguments[1]));app.prepare();let loop=app.residentAgentLoop!
        func eventually(_ label:String,_ condition:()->Bool) async throws {
            for _ in 0..<500 {if condition() {return};try await Task.sleep(for:.milliseconds(10))}
            preconditionFailure("real authority condition timed out: \(label); loop=\(loop.snapshot); runs=\(app.runs) cancelled=\(app.cancelledInvocations) pauses=\(app.wishMachineCoordinator.pauses)")
        }
        loop.setBackgroundEnabled(true);_ = await loop.restoreMemory();loop.tick()
        await Task.yield()
        try await eventually("first claim") {loop.tick();return app.runs==1}
        precondition(loop.snapshot.isBackgroundRun && loop.snapshot.isRunning,"real background turn started")
        app.beginEditing()
        precondition(app.wishMachineCoordinator.pauses == 0,"temporary editor cancellation never persists wish pause")
        precondition(!loop.snapshot.isStopped && !loop.snapshot.intentPausedByUser,"editor never becomes user stop")
        try await eventually("first cancellation") {app.cancelledInvocations==1}
        loop.setBackgroundEnabled(true)
        loop.receiveContinuationEvent(.init(id:"ready",kind:"wish.ready",summary:"ready"))
        app.now=app.now.addingTimeInterval(2);loop.tick();await Task.yield()
        try await eventually("continuation claim") {app.runs==2}
        precondition(app.runs == 2 && loop.snapshot.isBackgroundRun,"ready continuation actually resumes a new observation turn after editing")
        app.beginEditing()
        loop.stop()
        try await eventually("stop pause receipt") {app.wishMachineCoordinator.pauses==1 && app.cancelledInvocations==2 && loop.snapshot.intentPausedByUser}
        precondition(app.wishMachineCoordinator.pauses == 1,"explicit stop during editing persists pause")
        loop.setBackgroundEnabled(true)
        precondition(loop.snapshot.isStopped && loop.snapshot.intentPausedByUser,"editor exit never undoes explicit stop")
        // 换空间/退出走 invalidate()：作废本轮，但既不改用户停止状态，也不写持久暂停。
        loop.invalidate()
        precondition(app.wishMachineCoordinator.pauses == 1,"context switch or quit never persists a wish pause")
        precondition(loop.snapshot.isStopped && loop.snapshot.intentPausedByUser,
                     "context switch or quit never fabricates or clears a user stop")
        let events=try await app.readScheduler()["events"] as! [[String:Any]]
        precondition(events.count==2 && events.allSatisfy{$0["state"] as? String == "cancelled" && $0["receipt"] is [String:Any]},"actual cancellation receipts retain both charged invocations")
        print("ACTUAL Rust: persistedClaims=2 confirmedCancelledInvocations=2 explicitPauseCallbacks=1; no third invocation")
        print("PASS: actual loop editor temporary cancellation and explicit stop")
    }
}
"""#
let dir=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-prop-editor-loop-\(UUID())")
try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
defer{try? FileManager.default.removeItem(at:dir)}
let file=dir.appendingPathComponent("Test.swift"),exe=dir.appendingPathComponent("test")
try harness.write(to:file,atomically:true,encoding:.utf8)
func run(_ path:String,_ args:[String]) throws->Int32{let p=Process();p.executableURL=URL(fileURLWithPath:path);p.arguments=args;try p.run();p.waitUntilExit();return p.terminationStatus}
let code=try run("/usr/bin/swiftc",["-j1","-swift-version","6","-parse-as-library","apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift","tools/fixtures/PrivateAttachmentAuthority.swift","apps/macos/Sources/GMGNRadio/Presence/RustResidentSchedulerClient.swift","apps/macos/Sources/GMGNRadio/Agent/RustResidentIntentClient.swift","apps/macos/Sources/GMGNRadio/Agent/ResidentSteeringDelivery.swift","apps/macos/Sources/GMGNRadio/Agent/ResidentAgentLoop.swift","apps/macos/Sources/GMGNRadio/Agent/ResidentMemoryStore.swift","apps/macos/Sources/GMGNRadio/Agent/ResidentStateClient.swift",file.path,"-o",exe.path])
guard code == 0 else {exit(code)}
if CommandLine.arguments.contains("--compile-only") {print("PASS: actual editor loop fixture compiled; runtime not executed");exit(0)}
guard CommandLine.arguments.count>=3 else {print("FAIL: requires private endpoint and root; no nil scheduler fallback");exit(1)}
exit(try run(exe.path,Array(CommandLine.arguments.dropFirst())))
