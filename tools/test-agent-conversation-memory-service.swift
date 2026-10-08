// Current read-only memory contract + actual Rust-owned world client consumer.
// No provider, CLI, audio, taskd or user database is started.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-memory-rust-fixture-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: work) }
let harness = ##"""
import Foundation
// Unused default bootstrap is denied; all exercised clients inject exact JSON RPC.
struct WorldAuthorityEndpoint { static func taskServiceRoot() -> URL { URL(fileURLWithPath: "/fixture-unavailable") } }
final class TaskdHTTPAuthorityClient: @unchecked Sendable {
 init(endpointFile:String,helperPath:String,allowsLaunching:Bool=true,timeout:Double=5) {}
 func call(method:String,params:[String:Any]) throws -> [String:Any] {
  guard method=="product_settings_import" || method=="product_settings_read" else {throw RustCodexSessionClient.ClientError.transport}
  return ["revision":1,"imported":true,"values":["locale":"zh-CN","residentPersona":"fixture","backgroundTurnsPerHour":6,"autoSpeak":false,"autonomyEnabled":true,"agentBackend":"codex","selectedWorldID":NSNull(),"defaultSpace":"living-pod","djHostPrompt":"","djTakeover":true,"djPlanningModel":NSNull(),"ttsProvider":"bailian","ttsModel":"fixture","ttsVoice":"Cherry","asrProvider":"bailian","asrModel":"fixture","microphoneDeviceID":NSNull(),"orbRed":0.16,"orbGreen":0.62,"orbBlue":1.0,"orbFlowIntensity":0.82,"remoteMotionCatalogURL":"https://192.168.1.85:8765/catalog.json","shortcutAssignments":[],"globalShortcutsEnabled":true,"mediaKeysEnabled":true,"musicConnectedProviders":[]]]
 }
}
@MainActor var checks=0
@MainActor func check(_ yes:Bool,_ message:String) { checks += 1; if !yes {fatalError(message)} }
@MainActor final class Memory: ResidentStateTransport, @unchecked Sendable {
 var calls:[(String,[String:ResidentStateJSON])]=[]; var fail=false; var empty=false
 var blockNext=false;var pending:CheckedContinuation<Void,Never>?
 func call(method:String,params:[String:ResidentStateJSON]) async throws -> [String:ResidentStateJSON] {
  calls.append((method,params)); if blockNext {blockNext=false;await withCheckedContinuation{pending=$0}};if fail {throw ResidentStateError.daemon("memory_storage_failed")}
  guard method=="memory_recall" else {fatalError("memory must stay read-only")}
  let fresh=params["freshSession"]?.boolValue == true
  return ["status":.string(empty ? "unconfigured":"ok"),"revision":.number(1),"vectorGeneration":.number(0),"context":.string(empty ? "":fresh ? "【整段恢复段】":"【本轮相关】"),"facts":.array([]),"notes":.array([]),"pendingTurns":.number(0)]
 }
}
final class RPC: @unchecked Sendable {
 let lock=NSLock(); var starts:[[String:Any]]=[]; var blocked=false; var cancelled=false
 var threads:[String:String]=[:]
 var reply="fixture reply"
 func call(_ method:String,_ data:Data) throws -> Data {
  lock.lock();defer{lock.unlock()};let p=try JSONSerialization.jsonObject(with:data) as! [String:Any]
  guard p["worldID"] as? String != nil,p["residentScope"] as? String != nil,p["hostSessionID"] as? String=="fixture-host",p["runID"] as? String != nil,p["eventID"] as? String != nil else {throw RustCodexSessionClient.ClientError.identityMismatch}
  switch method {
  case "agent_cli_reset":threads.removeValue(forKey:p["worldID"] as! String);return Data("{\"reset\":true}".utf8)
  case "agent_cli_start":starts.append(p);cancelled=false;return Data("{}".utf8)
  case "agent_cli_cancel":cancelled=true;return Data("{}".utf8)
  case "agent_cli_read":
   let world=p["worldID"] as! String
   if p["continuity"] as? Bool == true{return try JSONSerialization.data(withJSONObject:["threadID":threads[world] as Any? ?? NSNull(),"freshSession":threads[world]==nil])}
   if !cancelled && !blocked{threads[world]="native-thread"}
   return try JSONSerialization.data(withJSONObject:["state":cancelled ? "cancelled":blocked ? "running":"completed","text":cancelled ? "late discarded":blocked ? "":reply,"threadID":"native-thread","turnID":"native-turn","pendingTools":[[String:Any]]()])
  default:throw RustCodexSessionClient.ClientError.invalidProtocol
  }
 }
 func prompts()->[String] {lock.lock();defer{lock.unlock()};return starts.map{($0["input"] as? [[String:Any]] ?? []).compactMap{$0["text"] as? String}.joined()}}
 func resume()->String? {lock.lock();defer{lock.unlock()};return (starts.last?["configuration"] as? [String:Any])?["resumeThreadID"] as? String}
 func setBlocked(_ value:Bool) {lock.lock();defer{lock.unlock()};blocked=value}
 func thread(_ world:String)->String?{lock.lock();defer{lock.unlock()};return threads[world]}
}
struct Locator: AgentExecutableLocating {func locate(executableNames:[String])->URL?{URL(fileURLWithPath:"/fixture/codex")}}
final class PlainRPC: @unchecked Sendable {
 let lock=NSLock();var history:[String:Int]=[:];var inputs:[String]=[]
 func call(_ method:String,_ data:Data)throws->Data {
  lock.lock();defer{lock.unlock()};let p=try JSONSerialization.jsonObject(with:data) as! [String:Any]
  guard p["worldID"]==nil,p["runID"]==nil,p["hostSessionID"] is String else{fatalError("ordinary chat fabricated world identity")}
  let key=(p["backend"] as! String)+"|"+(p["scopeID"] as! String)
  switch method {
  case "agent_chat_import":return Data("{\"imported\":true}".utf8)
  case "agent_chat_start":inputs.append(p["input"] as! String);return try JSONSerialization.data(withJSONObject:["state":"running","requestID":p["requestID"]!])
  case "agent_chat_reset":history[key]=0;return Data("{\"reset\":true}".utf8)
  case "agent_chat_read":
   let count=history[key] ?? 0
   if p["requestID"]==nil {return try JSONSerialization.data(withJSONObject:["freshSession":count==0,"historyCount":count,"sessionID":count==0 ? NSNull():"plain-native" as Any])}
   history[key]=min(6,count+2);return Data("{\"state\":\"completed\",\"reply\":\"ordinary\",\"sessionID\":\"plain-native\"}".utf8)
  default:throw RustChatClient.ClientError.invalidProtocol
  }
 }
 func prompts()->[String] {lock.lock();defer{lock.unlock()};return inputs}
}
@MainActor var latestPlain:PlainRPC?
@MainActor func world(_ id:String)->ResidentWorldContext {.init(selectedWorldID:id,worldID:id,displayName:nil,revision:1,residentPosition:nil,activeActivity:nil,activityPhase:nil,objects:[],availableActivities:[])}
@MainActor func tools(_ world:ResidentWorldContext,_ rpc:RPC)->ResidentConversationTools {
 let i=RustCodexSessionClient.Identity(worldID:world.worldID!,residentScope:world.sessionScope,hostSessionID:"fixture-host",runID:UUID().uuidString,eventID:UUID().uuidString)
 return .init(worldID:world.worldID!,schemasJSON:Data(#"[{"name":"read_world_state","description":"fixture","inputSchema":{"type":"object","properties":{},"additionalProperties":false}}]"#.utf8),call:{_,_,_ in fatalError("unexpected host side effect")},cancel:{},rustBinding:.init(identity:i,transport:rpc.call,environment:[:],effects:["read_world_state":"read"],authorize:{_ in "fixture-operation"}))
}
@MainActor func service(_ memory:Memory?)->AgentConversationService {
 let defaults=UserDefaults(suiteName:"fixture-\(UUID())")!;defaults.removePersistentDomain(forName:defaults.volatileDomainNames.first ?? "fixture")
 let ordinary=PlainRPC();latestPlain=ordinary;let plain=RustChatClient(call:ordinary.call)
 let service=AgentConversationService(locator:Locator(),defaults:defaults,rustChatClient:plain,plainChatEnvironment:{[:]})
 if let memory{service.attachConversationMemory(ResidentConversationMemory(transport:memory))};return service
}
@main struct Test {
 @MainActor static func main() async throws {
  let memory=Memory(),rpc=RPC(),s=service(memory),a=world("cabin")
  let reply=try await s.send("assembled user turn",worldContext:a,worldTools:tools(a,rpc),userMessage:"真实输入")
  check(reply=="fixture reply","real Rust client completed reply")
  check(memory.calls.count==1 && memory.calls[0].1["query"]?.stringValue=="真实输入","only real user text is recalled")
  check(memory.calls[0].1["freshSession"]?.boolValue==true,"first native thread is fresh")
  check(rpc.prompts().last!.contains("【整段恢复段】"),"same turn gets opaque recall data")
  _=try await s.send("second turn",worldContext:a,worldTools:tools(a,rpc),userMessage:"第二句")
  check(memory.calls[1].1["freshSession"]?.boolValue==false,"native session continuation is not fresh")
  check(rpc.prompts().last!.contains("【本轮相关】") && !rpc.prompts().last!.contains("【整段恢复段】"),"continuation does not replay restore segment")
  check(rpc.thread("cabin")=="native-thread" && s.preferenceStore.sessionID(for:.codex,scope:a.sessionScope+".tools.v8")==nil,"actual native thread persists in Rust authority, not UserDefaults")
  let count=memory.calls.count
  _=try await s.send("background assembled prompt",worldContext:a,worldTools:tools(a,rpc),userMessage:"")
  check(memory.calls.count==count,"empty background input creates no recall")
  _=try await s.send("background without user",worldContext:a,worldTools:tools(a,rpc))
  check(memory.calls.count==count,"absent background input is never invented")
  let b=world("room");_=try await s.send("new world",worldContext:b,worldTools:tools(b,rpc),userMessage:"世界乙")
  check(memory.calls.last!.1["scope"]?.objectValue?["worldID"]?.stringValue=="room","scope switches to actual world")
  check(memory.calls.last!.1["freshSession"]?.boolValue==true,"new world has separate native continuity")
  rpc.setBlocked(true);let n=rpc.prompts().count
  let task=Task {try await s.send("pending",worldContext:b,worldTools:tools(b,rpc),userMessage:"取消输入")}
  while rpc.prompts().count==n {await Task.yield()}
  s.cancel();do {_=try await task.value;fatalError("cancel must not complete")}catch is CancellationError{}catch AgentConversationError.cancelled{}
  check(rpc.thread("room")=="native-thread","late cancelled reply does not replace persisted session")
  rpc.setBlocked(false);s.resetSession()
  _=try await s.send("after reset",worldContext:b,worldTools:tools(b,rpc),userMessage:"重置后")
  check(memory.calls.last!.1["freshSession"]?.boolValue==true,"reset clears native continuity")
  let failed=Memory();failed.fail=true;let f=service(failed);var notice:String?;f.attachConversationMemory(ResidentConversationMemory(transport:failed),onMemoryError:{notice=$0})
  check(try await f.send("still works",worldContext:a,worldTools:tools(a,rpc),userMessage:"失败后仍聊")=="fixture reply","memory failure does not replace Rust reply")
  check(notice != nil,"memory failure is visible")
  let empty=Memory();empty.empty=true;let e=service(empty)
  _=try await e.send("empty memory",worldContext:a,worldTools:tools(a,rpc),userMessage:"空记忆")
  check(!rpc.prompts().last!.contains("记忆背景"),"empty recall adds no fake context")
  let unbound=service(nil);_=try await unbound.send("no memory",worldContext:a,worldTools:tools(a,rpc),userMessage:"无记忆")
  let plainMemory=Memory();let plain=service(plainMemory);check(try await plain.send("ordinary")=="ordinary","non-world Rust chat uses no fake claim")
  check(plainMemory.calls.isEmpty,"plain chat with no world scope binds no memory")
  let ordinaryMemory=Memory();let ordinary=service(ordinaryMemory);let ordinaryRPC=latestPlain!
  _=try await ordinary.send("真实普通世界输入",worldContext:a)
  check(ordinaryMemory.calls[0].1["query"]?.stringValue=="真实普通世界输入","ordinary world context retains actual user query")
  check(ordinaryMemory.calls[0].1["freshSession"]?.boolValue==true,"ordinary first recall uses Rust fresh metadata")
  check(ordinaryRPC.prompts()[0].contains("【整段恢复段】"),"ordinary same turn includes recalled context")
  _=try await ordinary.send("普通续聊",worldContext:a)
  check(ordinaryMemory.calls[1].1["freshSession"]?.boolValue==false,"ordinary continuation uses confirmed Rust history")
  check(ordinaryRPC.prompts()[1].contains("【本轮相关】") && !ordinaryRPC.prompts()[1].contains("【整段恢复段】"),"ordinary continuation avoids old restore replay")
  check(ordinary.preferenceStore.sessionID(for:.codex,scope:a.sessionScope)==nil,"ordinary native continuation is not written back to UserDefaults")
  let recalled=ordinaryMemory.calls.count
  _=try await ordinary.send("background assembled",worldContext:a,userMessage:"")
  check(ordinaryMemory.calls.count==recalled,"ordinary empty background input recalls nothing")
  ordinary.resetSession();_=try await ordinary.send("普通重置后",worldContext:a)
  check(ordinaryMemory.calls.last!.1["freshSession"]?.boolValue==true,"ordinary reset uses Rust metadata rather than UserDefaults")
  _=try await ordinary.send("切空间",worldContext:b)
  check(ordinaryMemory.calls.last!.1["freshSession"]?.boolValue==true,"ordinary other world is a separate scope")
  let delayed=Memory();delayed.blockNext=true;let delayedService=service(delayed);let delayedRPC=latestPlain!
  let oldRecall=Task {try await delayedService.send("late memory",worldContext:a)}
  while delayed.pending==nil {await Task.yield()};delayedService.cancel();delayed.pending!.resume();delayed.pending=nil
  do {_=try await oldRecall.value;fatalError("cancelled recall must not dispatch")}catch is CancellationError{}
  check(delayedRPC.prompts().isEmpty,"cancel during recall blocks later CLI admission")
  delayed.blockNext=true;let staleRecall=Task {try await delayedService.send("old world memory",worldContext:a)}
  while delayed.pending==nil {await Task.yield()}
  _=try await delayedService.send("new world memory",worldContext:b)
  delayed.pending!.resume();delayed.pending=nil
  do {_=try await staleRecall.value;fatalError("old world recall must not dispatch")}catch is CancellationError{}
  check(delayedRPC.prompts().count==1 && delayedRPC.prompts()[0].contains("new world memory"),"world scope switch isolates late recall from the admitted turn")
  let ordinaryFailure=Memory();ordinaryFailure.fail=true;let ordinaryFailedService=service(ordinaryFailure);var ordinaryNotice:String?
  ordinaryFailedService.attachConversationMemory(ResidentConversationMemory(transport:ordinaryFailure),onMemoryError:{ordinaryNotice=$0})
  check(try await ordinaryFailedService.send("普通召回失败继续",worldContext:a)=="ordinary","ordinary recall failure leaves actual Rust chat available")
  check(ordinaryNotice != nil,"ordinary memory failure remains visible")
  check(memory.calls.allSatisfy{$0.0=="memory_recall"},"completion cancellation reset never write removed raw-memory layer")
  print("PASS: \(checks) actual Rust conversation memory checks")
 }
}
"""##
let main = work.appendingPathComponent("main.swift"), binary = work.appendingPathComponent("test")
try harness.write(to:main,atomically:true,encoding:.utf8)
let agent = ["CodexCLI","AgentConversationService","ResidentCodexTransport","ResidentCodexPolicy","ResidentCodexAgent","ResidentSteeringDelivery","ResidentDSHTransport","ResidentDSHConfiguration","ResidentStateClient","ResidentMemoryClient","ResidentConversationMemory","ResidentDSHAgentToolBridge","ResidentDSHHostToolsBridge","ResidentClaudeToolBridge","ResidentClaudeProcessRunner"]
let presence = ["ResidentVisionCapture","RetryBackoff","RustCodexSessionClient","RustDSHSessionClient","RustResidentClaudeClient","RustChatClient","RustProductSettingsClient"]
let compile=Process();compile.executableURL=URL(fileURLWithPath:"/usr/bin/swiftc")
compile.arguments=["-swift-version","6","-j1","-parse-as-library"]
compile.arguments! += agent.map{root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/\($0).swift").path}
compile.arguments! += presence.map{root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/\($0).swift").path}
compile.arguments! += [main.path,"-o",binary.path]
try compile.run();compile.waitUntilExit();guard compile.terminationStatus==0 else{exit(compile.terminationStatus)}
let test=Process();test.executableURL=binary;try test.run();test.waitUntilExit();exit(test.terminationStatus)
