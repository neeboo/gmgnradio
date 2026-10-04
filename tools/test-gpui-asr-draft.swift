// Run the production ASR provider callback with a persistence trap: selection must stay draft-only.
import Foundation
let source = try String(contentsOfFile:"apps/macos/ProductHost/ProductHost.swift", encoding:.utf8)
let start = source.range(of:"        case \"asr.provider\":")!.lowerBound
let end = source.range(of:"        case \"asr.save\":", range:start..<source.endIndex)!.lowerBound
let callback = String(source[start..<end])
let cancelStart = source.range(of:"        case \"speech.settings.cancel\":")!.lowerBound
let cancelEnd = source.range(of:"        case \"speech.settings.load\":", range:cancelStart..<source.endIndex)!.lowerBound
let cancelCallback = String(source[cancelStart..<cancelEnd])
let harness = #"""
import Foundation
enum RustVoiceProvider: String { case bailian, elevenlabs }
struct Caps { var id: String; var asrModels: [String] }
struct Capabilities { var providers: [Caps] }
final class Test {
    var capabilities: Capabilities? = .init(providers:[.init(id:"bailian",asrModels:["model"]),.init(id:"elevenlabs",asrModels:["model"])])
    var asrDraftProvider: RustVoiceProvider?
    var capabilitiesTask: Task<Void,Never>?
    var loadingCapabilities = true
    var voices = ["old"]
    var notice: String? = "old"
    var stopped = 0
    func stopVoiceWork() { stopped += 1 }
    func command(_ value:[String:Any]) -> Bool {
        switch value["op"] as? String {
        \#(callback)
        \#(cancelCallback)
        default: return false
        }
        return true
    }
}
let ui = Test()
precondition(ui.command(["op":"asr.provider","id":"elevenlabs"]))
precondition(ui.asrDraftProvider == .elevenlabs)
precondition(!ui.command(["op":"asr.provider","id":"unknown"]))
precondition(ui.asrDraftProvider == .elevenlabs)
ui.capabilities = nil
precondition(!ui.command(["op":"asr.provider","id":"bailian"]))
let capability = Task<Void,Never> {}
ui.capabilitiesTask = capability
precondition(ui.command(["op":"speech.settings.cancel","clearVoices":true,"cancelCapabilities":false]))
precondition(!capability.isCancelled && ui.capabilitiesTask != nil && ui.loadingCapabilities)
precondition(ui.stopped == 1 && ui.voices.isEmpty && ui.notice == nil)
precondition(ui.command(["op":"speech.settings.cancel"]))
precondition(capability.isCancelled && ui.capabilitiesTask == nil && !ui.loadingCapabilities)
print("PASS: 10 production ASR draft / speech cancel assertions; no persistence API, host or credentials")
"""#
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-asr-draft-\(UUID())")
try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:dir)}
let file=dir.appendingPathComponent("main.swift"); try harness.write(to:file,atomically:true,encoding:.utf8)
let runner=Process();runner.executableURL=URL(fileURLWithPath:"/usr/bin/swift");runner.arguments=[file.path]
try runner.run();runner.waitUntilExit();precondition(runner.terminationStatus==0)
