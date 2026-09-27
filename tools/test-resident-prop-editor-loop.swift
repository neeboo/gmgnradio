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
let harness = #"""
import Foundation
@MainActor final class Coordinator {
    var pauses=0
    func pauseContinuations(worldID:String,residentScope:String)throws{pauses += 1}
}
@MainActor final class App {
    var residentPropTemporaryCancellation=false
    var residentAgentLoop:ResidentAgentLoop?
    let wishMachineCoordinator=Coordinator()
    private var residentWishScope:ResidentWishScope?
    var runs=0
    var now=Date(timeIntervalSince1970:100)
    func showResidentVoiceStatus(_ message:String) { }
    \#(methods)
    func prepare() {
        let loop=ResidentAgentLoop(now:{[weak self] in self?.now ?? Date()},configuration:.init(minimumWakeInterval:1),run:{[weak self] input in
            self?.runs += 1
            try await Task.sleep(for:.seconds(30));return "done"
        },steer:{_ in .notDelivered},onReply:{_ in},onFailure:{_ in},onChange:{},onCancel:{[weak self] in self?.pauseResidentWishContinuations()})
        residentAgentLoop=loop
        residentWishScope=ResidentWishScope(loopID:ObjectIdentifier(loop),worldID:"room",residentScope:"resident")
    }
    func beginEditing() { temporarilyPauseResidentForPropEditing() }
}
@main struct Tests {
    @MainActor static func main() async throws {
        let app=App();app.prepare();let loop=app.residentAgentLoop!
        loop.setBackgroundEnabled(true);loop.tick()
        await Task.yield()
        precondition(loop.snapshot.isBackgroundRun && loop.snapshot.isRunning,"real background turn started")
        app.beginEditing()
        precondition(app.wishMachineCoordinator.pauses == 0,"temporary editor cancellation never persists wish pause")
        precondition(!loop.snapshot.isStopped && !loop.snapshot.intentPausedByUser,"editor never becomes user stop")
        loop.setBackgroundEnabled(true)
        loop.receiveContinuationEvent(.init(id:"ready",kind:"wish.ready",summary:"ready"))
        app.now=app.now.addingTimeInterval(2);loop.tick();await Task.yield()
        precondition(app.runs == 2 && loop.snapshot.isBackgroundRun,"ready continuation actually resumes a new observation turn after editing")
        app.beginEditing()
        loop.stop()
        precondition(app.wishMachineCoordinator.pauses == 1,"explicit stop during editing persists pause")
        loop.setBackgroundEnabled(true)
        precondition(loop.snapshot.isStopped && loop.snapshot.intentPausedByUser,"editor exit never undoes explicit stop")
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
let code=try run("/usr/bin/swiftc",["-j1","-parse-as-library","apps/macos/Sources/GMGNRadio/Agent/ResidentSteeringDelivery.swift","apps/macos/Sources/GMGNRadio/Agent/ResidentAgentLoop.swift","apps/macos/Sources/GMGNRadio/Agent/ResidentMemoryStore.swift","apps/macos/Sources/GMGNRadio/Agent/ResidentStateClient.swift",file.path,"-o",exe.path])
guard code == 0 else {exit(code)}
exit(try run(exe.path,[]))
