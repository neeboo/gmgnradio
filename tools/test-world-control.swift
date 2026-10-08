// Production typed client → authenticated private taskd HTTP. No formal app/CLI/audio.
import Foundation
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
// taskd rejects symlink ancestors; macOS /var and /tmp are aliases.
let work=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("gmgn-world-control-\(UUID())")
try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:work) }
let source = #"""
import Foundation
import WorldRuntime
final class TaskdHTTPAuthorityClient: @unchecked Sendable {
    init(endpointFile:String,helperPath:String,allowsLaunching:Bool,timeout:Double) {}
    func call(method:String,params:[String:Any]) throws -> [String:Any] { throw FixtureError.unusedTransport }
}
@MainActor final class ResidentWorldToolSession {
    struct RustDispatchAuthority: Sendable {
        let worldID:String; let residentScope:String; let hostSessionID:String
        let runID:String; let callID:String; let operationID:String; let toolName:String
    }
}
enum FixtureError:Error { case unusedTransport, failed(String) }
final class Response: @unchecked Sendable { let lock=NSLock(); var data:Data?; var error:Error? }
func rpc(endpoint:String,method:String,input:Data)throws->Data {
    let e=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:endpoint))) as! [String:Any]
    guard let address=e["address"] as? String,address.hasPrefix("127.0.0.1:"),let token=e["token"] as? String else {throw FixtureError.failed("private_endpoint")}
    var request=URLRequest(url:URL(string:"http://"+address+"/rpc")!,timeoutInterval:8)
    request.httpMethod="POST";request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
    request.setValue("application/json",forHTTPHeaderField:"Content-Type")
    let requestID=UUID().uuidString
    request.httpBody=try JSONSerialization.data(withJSONObject:["id":requestID,"method":method,"params":JSONSerialization.jsonObject(with:input)])
    let reply=Response(),done=DispatchSemaphore(value:0)
    let task=URLSession.shared.dataTask(with:request){data,_,error in reply.lock.lock();reply.data=data;reply.error=error;reply.lock.unlock();done.signal()};task.resume()
    guard done.wait(timeout: .now() + 10) == .success else {task.cancel();throw FixtureError.failed("http_timeout")}
    if let error=reply.error {throw error}
    let wire=try JSONSerialization.jsonObject(with:reply.data!) as! [String:Any]
    guard wire["id"] as? String == requestID else {throw FixtureError.failed("rpc_identity")}
    if let error=wire["error"] as? [String:Any] {throw FixtureError.failed(error["code"] as? String ?? "rpc_rejected")}
    guard wire["result"] != nil else {throw FixtureError.failed("rpc_missing_result")}
    return try JSONSerialization.data(withJSONObject:wire["result"]!)
}
@main struct Main {
    static func main() async throws {
        let directory=CommandLine.arguments[1],endpoint=directory+"/taskd.endpoint.json"
        let daemon=Process();daemon.executableURL=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TASKD_BIN"] ?? FileManager.default.currentDirectoryPath+"/target/debug/gmgn-taskd")
        daemon.arguments=["--root",directory,"--endpoint-file",endpoint,"--concurrency","1"]
        daemon.standardOutput=FileHandle.nullDevice;daemon.standardError=FileHandle.standardError
        try daemon.run();defer {if daemon.isRunning {daemon.terminate();daemon.waitUntilExit()}}
        for _ in 0..<100 {if FileManager.default.fileExists(atPath:endpoint){break};try await Task.sleep(nanoseconds:20_000_000)}
        guard FileManager.default.fileExists(atPath:endpoint) else {throw FixtureError.failed("private_daemon_endpoint_unavailable")}
        let call:RustWorldControlClient.Call={try rpc(endpoint:endpoint,method:$0,input:$1)}
        func request(_ method:String,_ params:[String:Any])throws->Data {try call(method,JSONSerialization.data(withJSONObject:params))}
        let id=RustWorldControlClient.Identity(worldID:"fixture",residentScope:"private-ui",hostSessionID:UUID().uuidString)
        let transform:[String:Any]=["position":["x":0,"y":0,"z":0],"rotation":["x":0,"y":0,"z":0,"w":1],"scale":["x":1,"y":1,"z":1]]
        _=try request("world_commit",["worldID":id.worldID,"requestID":"seed","expectedRevision":0,"ops":[["op":"replaceState","state":["worldID":id.worldID,"revision":0,"worldTime":1000,"lastObservedWallTime":1000,"weather":"clear","completedGoals":[:],"objectStates":[:],"agentTransform":transform]]]])
        let client=RustWorldControlClient(call:call)
        let camera=WorldCameraAnchor(id:"wide",transform:WorldTransform(position:.init(x:0,y:0,z:0),rotation:.init(x:0,y:0,z:0,w:1),scale:.init(x:1,y:1,z:1)),fieldOfViewDegrees:55,nearPlane:0.1,farPlane:100)
        let weather=try await client.perform(identity:id,cameras:[camera],expectedRevision:1,requestID:"rain",command:JSONSerialization.data(withJSONObject:["op":"weather","weather":"rain"]),agent:nil,uiRequested:true)
        guard weather.snapshot.record.state.weather == .rain,weather.events.count == 1 else {throw FixtureError.failed("weather_receipt")}
        let goal=try await client.perform(identity:id,cameras:[camera],expectedRevision:weather.snapshot.record.recordRevision,requestID:"goal",command:JSONSerialization.data(withJSONObject:["op":"goal","goalID":"  done  ","summary":"  actual  "]),agent:nil,uiRequested:true)
        guard let saved=goal.snapshot.record.state.completedGoals["done"],saved.summary=="actual",saved.completedAt.timeIntervalSince1970==1 else {throw FixtureError.failed("goal_authority_clock")}
        let moved=try await client.perform(identity:id,cameras:[camera],expectedRevision:goal.snapshot.record.recordRevision,requestID:"camera",command:JSONSerialization.data(withJSONObject:["op":"camera","cameraID":"wide"]),agent:nil,uiRequested:true)
        guard moved.snapshot.record.state.liveCamera?.anchorID=="wide",moved.snapshot.record.state.liveCamera?.fieldOfViewDegrees==55 else {throw FixtureError.failed("camera_catalog")}
        do {_=try await client.perform(identity:id,cameras:[camera],expectedRevision:moved.snapshot.record.recordRevision,requestID:"missing-agent",command:JSONSerialization.data(withJSONObject:["op":"weather","weather":"clear"]),agent:nil,uiRequested:false);throw FixtureError.failed("missing_agent_accepted")} catch RustWorldControlClient.Failure.unavailable {}
        print("PASS: production world control client, real private HTTP, weather/camera/goal clock, explicit UI and missing-agent gate")
    }
}
"""#
let main=work.appendingPathComponent("Main.swift");try source.write(to:main,atomically:true,encoding:.utf8)
let flagsProcess=Process(),pipe=Pipe();flagsProcess.executableURL=URL(fileURLWithPath:"/bin/sh");flagsProcess.arguments=[root.appendingPathComponent("tools/world-runtime-harness-flags.sh").path];flagsProcess.standardOutput=pipe;try flagsProcess.run();flagsProcess.waitUntilExit();guard flagsProcess.terminationStatus==0 else {exit(flagsProcess.terminationStatus)}
let flags=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).split(separator:"\n").map(String.init)
let binary=work.appendingPathComponent("test"),compile=Process();compile.executableURL=URL(fileURLWithPath:"/usr/bin/swiftc");compile.arguments=["-j1","-parse-as-library"]+flags+[root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/RustWorldControlClient.swift").path,main.path,"-o",binary.path]
try compile.run();compile.waitUntilExit();guard compile.terminationStatus==0 else {exit(compile.terminationStatus)}
if ProcessInfo.processInfo.environment["GMGN_FIXTURE_COMPILE_ONLY"]=="1" {print("PASS: world control consumer compiled only");exit(0)}
let daemonRoot=work.appendingPathComponent("service");try FileManager.default.createDirectory(at:daemonRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
let test=Process();test.executableURL=binary;test.arguments=[daemonRoot.path];try test.run();test.waitUntilExit();exit(test.terminationStatus)
