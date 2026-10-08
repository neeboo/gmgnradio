// Isolated Swift 6 consumer fixture. No app, provider, keychain or user DB access.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-settings-fixture-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: work) }
let source = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Settings/AgentSettingsModel.swift"), encoding: .utf8)
let speech = source.components(separatedBy: "struct BailianRealtimeModelOption")[0]
let extracted = work.appendingPathComponent("Speech.swift")
try speech.write(to: extracted, atomically: true, encoding: .utf8)
let shortcuts = work.appendingPathComponent("Shortcuts.swift")
let shortcutSource = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Settings/GMGNKeyboardShortcuts.swift"), encoding: .utf8)
try shortcutSource.components(separatedBy: "private let gmgnGlobalHotKeySignature")[0].write(to: shortcuts, atomically: true, encoding: .utf8)
let hostFixture = work.appendingPathComponent("BackendHost.swift")
let hostSource = try String(contentsOf: root.appendingPathComponent("apps/macos/UnityHost/UnityMediaHost.swift"), encoding: .utf8)
let hostSelection = "    private lazy var agentConnection:" + hostSource.components(separatedBy: "    private lazy var agentConnection:")[1].components(separatedBy: "    private struct QueueEntry")[0]
try ("""
import Foundation
@MainActor final class BackendProductProjection {
    let authority:RustProductSettingsClient
    init(_ authority:RustProductSettingsClient){self.authority=authority}
}
@MainActor final class BackendChatProjection {
    var backend:String
    var cancellations=0
    let installedBackendSnapshot:[[String:Any]] = [["id":"dsh"],["id":"codex"]]
    init(_ backend:String){self.backend=backend}
    func selectBackend(_ id:String)->Bool {
        guard installedBackendSnapshot.contains(where:{$0["id"] as? String==id})else{return false}
        if backend != id {backend=id;cancellations+=1};return true
    }
}
@MainActor final class BackendHostFixture {
    let productSettings:BackendProductProjection
    let chat:BackendChatProjection
    var closed=false,bindings=0
    init(_ settings:RustProductSettingsClient,_ backend:String){productSettings=BackendProductProjection(settings);chat=BackendChatProjection(backend)}
    func bindResidentSchedulerIfRequested(){bindings+=1}
    func command(_ value:[String:Any])async->Bool{await agentConnection.command(value)}
""" + "\n" + hostSelection + "\n}\n").write(to:hostFixture,atomically:true,encoding:.utf8)
let main = work.appendingPathComponent("Main.swift")
try ##"""
import Foundation
struct WorldAuthorityEndpoint { static func taskServiceRoot(applicationSupportBase:URL? = nil) -> URL { URL(fileURLWithPath:"/never") } }
final class TaskdHTTPAuthorityClient: @unchecked Sendable {
 init(endpointFile:String,helperPath:String,allowsLaunching:Bool,timeout:Double) {}
 func call(method:String,params:[String:Any]) throws -> [String:Any] { throw Failure.denied }
}
enum Failure:Error { case denied }
enum TaskdHTTPError:Error{case rejected(code:String)}
@MainActor final class InertInboxRPC {
 var revision=0,entries=[ResidentSystemInboxEntry](),unread=0,expiries=[String:Date](),changed=false,fail=false,requests=[String](),ids=[String]()
 func call(_ method:String,_ data:Data)async throws->Data {
  let p=try JSONSerialization.jsonObject(with:data) as! [String:Any]
  requests.append(method)
  if method != "inbox_control_read" {
   precondition(p["now"]==nil && p["updatedAt"]==nil)
   if method=="inbox_control_deliver" {precondition(p["deliveries"] != nil && p["entries"]==nil)}
   ids.append(p["requestID"] as! String)
   if fail{throw Failure.denied}
  }
  let encoder=JSONEncoder();encoder.dateEncodingStrategy = .secondsSince1970
  let value=RustInboxClient.Snapshot(revision:Int64(revision),entries:entries,unreadCount:unread,promptExpiries:expiries,changed:changed,replayed:false,legacyImported:true)
  return try encoder.encode(value)
 }
}
enum ResidentOwnershipProjection {
 static func sentence(generation:String,ownership:String,placement:String)->String{"inert-ownership"}
}
@MainActor func compileDefaultWishInitializer() { _ = WishMachineTaskPresentationStore() }
enum CodexAccountState:Equatable,Sendable{case unavailable,signedOut,signedIn(method:String)}
@MainActor protocol CodexAccountServicing:AnyObject {
 func status()async->CodexAccountState;func login()async throws;func logout()async throws
}
@MainActor final class CodexAgentAccountService:CodexAccountServicing {
 func status()async->CodexAccountState{.unavailable}
 func login()async throws{fatalError("live authentication forbidden")}
 func logout()async throws{fatalError("live authentication forbidden")}
}
struct MusicProviderID:RawRepresentable,Hashable,Sendable {
 let rawValue:String
 static let netease=Self(rawValue:"netease"),qqMusic=Self(rawValue:"qq-music"),appleMusic=Self(rawValue:"apple-music")
}
enum MusicAccountAuthorizationState{case disconnected,authorizing,connected,expired,denied,unavailable}
enum MusicSourceAccess{case local,accountRequired(MusicAccountAuthorizationState)}
@MainActor protocol MusicAccountServicing {
 func connect(providerID:MusicProviderID,cookie:String)async throws
 func disconnect(providerID:MusicProviderID)async throws
}
@MainActor protocol MusicProviderWebAuthenticating:AnyObject {
 func login(providerID:MusicProviderID)async throws->String
 func clearSession(providerID:MusicProviderID)async
}
enum MusicProviderWebLoginError:Error{case cancelled}
@MainActor final class MusicProviderWebLoginController:MusicProviderWebAuthenticating {
 func login(providerID:MusicProviderID)async throws->String{"inert-cookie-never-wire"}
 func clearSession(providerID:MusicProviderID)async{}
}
@MainActor final class MusicAccountCommandService:MusicAccountServicing {
 var fails=false;var authenticated=false
 static func live()->MusicAccountCommandService{Self()}
 func connect(providerID:MusicProviderID,cookie:String)async throws {guard !fails else{throw Failure.denied};authenticated=true}
 func disconnect(providerID:MusicProviderID)async throws {authenticated=false}
}
@MainActor final class AppleMusicSource {
 func access()async->MusicSourceAccess{.accountRequired(.disconnected)}
 func requestAuthorization()async->MusicSourceAccess{.accountRequired(.connected)}
}
enum E2ERuntime { static var defaults:UserDefaults { UserDefaults(suiteName:"inert-fixture")! }; static var applicationSupportBase:URL? { nil } }
enum RustVoiceProvider:String { case bailian,elevenlabs,fish }
struct RustVoiceConfiguration { let provider:RustVoiceProvider;let apiKey:String;let voiceID:String;let model:String? }
@MainActor struct ResidentPreferences {
 let defaults:UserDefaults;let settings:RustProductSettingsClient
 var backgroundTurnsPerHour:Int{settings.confirmed?.values.backgroundTurnsPerHour ?? 0}
}
@MainActor final class RustResidentSchedulerClient {}
@MainActor final class WorldAgentContext {
 struct Position{var x=0.0;var y=0.0;var z=0.0};struct Transform{var position=Position()}
 struct Phase{let rawValue="active"};struct Activity{let id="activity";let phase=Phase()}
 struct Snapshot{let worldID="fixture";let agentTransform=Transform();let activeActivity:Activity?=nil}
 struct Held{let objectID:String};struct State{var heldProp:Held?=nil}
 var snapshot=Snapshot();var state=State()
}
struct ResidentSelfState {
 let space:String;let position:[Double];let yawDegrees:Double?;let avatarFormat:String?
 let activityID:String?;let activityPhase:String?;let heldPropID:String?
}
@MainActor struct ResidentLoopTools {
 init(loop:ResidentAgentLoop,runID:UUID,selfState:@escaping()->ResidentSelfState?){}
}
// Scheduler is an inert boundary double; the settings event bridge is production source.
@MainActor final class ResidentAgentLoop {
 struct Input{let runID=UUID();let isBackground=false;let isHumanOrderedTurn=false}
 struct Event{}
 struct Snapshot:Codable{var isBackgroundRun=false;var isInvalidated=false;var isStopped=false}
 var snapshot=Snapshot();var lastFinishedRunWasBackground=false;var resumes=0
 init(now: @escaping @MainActor () -> Date, run: @escaping @MainActor (Input) async throws -> String, onReply: @escaping @MainActor (String) -> Void, onChange: @escaping @MainActor () -> Void, onCancel: @escaping @MainActor () -> Void){}
 func cancel(){};func setBackgroundEnabled(_ value:Bool){};func setBackgroundTurnsPerHour(_ value:Int){}
 func bindRustScheduler(_ s:RustResidentSchedulerClient?, availability: @escaping @MainActor () -> Bool){}
 func tick(){};func stop(){snapshot.isStopped=true}
 func resumeAutonomyByUser()->Bool{resumes+=1;snapshot.isStopped=false;return true}
 func receiveEvent(_ e:Event){};func receiveContinuationEvent(_ e:Event){}
 func invalidate(){snapshot.isInvalidated=true}
}
final class RPC:@unchecked Sendable {
 let lock=NSLock(); var revision=1;var fail=false;var calls=0;var receipts=0
 var shortcutState:[[String:Any]]=[];var global=true;var media=true;var providers=[String]()
 var holdBackend=false,backendPending=false,loseBackendReceipt=false,backendWrites=0
 let backendRelease=DispatchSemaphore(value:0)
 var values:[String:Any]=["locale":"zh-CN","residentPersona":"confirmed","backgroundTurnsPerHour":0,"autoSpeak":false,"autonomyEnabled":false,"agentBackend":"codex","selectedWorldID":NSNull(),"defaultSpace":"living-pod","djHostPrompt":"host","djTakeover":false,"djPlanningModel":NSNull(),"ttsProvider":"bailian","ttsModel":"fixture-model","ttsVoice":"Cherry","asrProvider":"bailian","asrModel":"fixture-asr","microphoneDeviceID":NSNull(),"orbRed":0.16,"orbGreen":0.62,"orbBlue":1.0,"orbFlowIntensity":0.82,"remoteMotionCatalogURL":"https://192.168.1.85:8765/catalog.json"]
 func call(_ method:String,_ data:Data)throws->Data {
  let input=try JSONSerialization.jsonObject(with:data) as! [String:Any]
  if method=="product_settings_apply",(input["changes"] as? [String:Any])?["agentBackend"] != nil {
   lock.lock();let held=holdBackend;if held{backendPending=true};lock.unlock()
   if held{precondition(backendRelease.wait(timeout:.now()+3) == .success)}
  }
  lock.lock();defer{lock.unlock()};calls+=1
  let p=input
  precondition(!String(decoding:data,as:UTF8.self).contains("inert-cookie-never-wire"))
  if method=="product_settings_shortcut_event" || method=="product_settings_music_receipt" {
   guard !fail else{throw Failure.denied};precondition(p["expectedRevision"] as? Int==revision)
   if method=="product_settings_music_receipt" {
    receipts+=1;let provider=p["providerID"] as! String
    if p["connected"] as! Bool{if !providers.contains(provider){providers.append(provider)}}else{providers.removeAll{$0==provider}}
   } else {
    let event=p["event"] as! [String:Any]
    if event["kind"] as? String=="globalEnabled"{global=event["enabled"] as! Bool}
    if event["kind"] as? String=="mediaKeysEnabled"{media=event["enabled"] as! Bool}
   };revision+=1
  }
  if method=="product_settings_apply" {
   guard !fail else {throw Failure.denied};precondition(p["expectedRevision"] as? Int==revision)
   let changes=p["changes"] as! [String:Any];precondition(changes["apiKey"]==nil)
   for(k,v)in changes{
    if k.hasPrefix("orb"),let number=v as? NSNumber {values[k]=k=="orbFlowIntensity" ? min(1.5,max(0.35,number.doubleValue)):min(1,max(0,number.doubleValue))}
    else{values[k]=v}
   };revision+=1
   if changes["agentBackend"] != nil {backendWrites+=1;if loseBackendReceipt{loseBackendReceipt=false;throw Failure.denied}}
  }
  var snapshot=values
  snapshot["avatarPositions"] = [String:[Double]]()
  snapshot["stagePointCloudChoice"] = "automatic"
  snapshot["stageParticleSizeMultiplier"] = 1.0
  snapshot["stageLegacyImported"] = false
  snapshot["stageLyricsMode"] = "automatic"
  snapshot["stageLyricsResolvedMode"] = "vinyl"
  snapshot["stageLyricsTrackID"] = NSNull()
  snapshot["stageLyricsLegacyImported"] = false
  snapshot["shortcutAssignments"]=shortcutState;snapshot["globalShortcutsEnabled"]=global;snapshot["mediaKeysEnabled"]=media;snapshot["musicConnectedProviders"]=providers
  return try JSONSerialization.data(withJSONObject:["revision":revision,"values":snapshot,"imported":true])
 }
 func denied(_ value:Bool){lock.lock();fail=value;lock.unlock()}
 func count()->Int{lock.lock();defer{lock.unlock()};return calls}
 func receiptCount()->Int{lock.lock();defer{lock.unlock()};return receipts}
 func holdNextBackend(){lock.lock();holdBackend=true;backendPending=false;lock.unlock()}
 func waitingBackend()->Bool{lock.lock();defer{lock.unlock()};return backendPending}
 func releaseBackend(){lock.lock();holdBackend=false;backendPending=false;lock.unlock();backendRelease.signal()}
 func loseNextBackendReceipt(){lock.lock();loseBackendReceipt=true;lock.unlock()}
 func backendWriteCount()->Int{lock.lock();defer{lock.unlock()};return backendWrites}
 func seed(_ data:Data)throws{lock.lock();defer{lock.unlock()};shortcutState=try JSONSerialization.jsonObject(with:data) as! [[String:Any]]}
}
@MainActor final class Secrets:ProductSpeechSecretStore {
 var keys=["bailian":"inert-old"];var imported=Set<String>();var reads=0;var markerReads=0
 func read(provider:String)->String?{reads += 1;return keys[provider]}
 func write(provider:String,key:String)throws{keys[provider]=key}
 func legacyImported(provider:String)->Bool{markerReads += 1;return imported.contains(provider)}
 func markLegacyImported(provider:String)throws{imported.insert(provider)}
}
@main struct Test {
 @MainActor static func main()async throws {
  let rpc=RPC(),client=RustProductSettingsClient(call:rpc.call)
  let suite="settings-fixture-\(UUID())",defaults=UserDefaults(suiteName:suite)!
  defer{defaults.removePersistentDomain(forName:suite)}
  try rpc.seed(JSONEncoder().encode(GMGNShortcutAssignment.defaults))
  defaults.set("legacy",forKey:"resident.persona.v1")
  defaults.set("inert-legacy",forKey:"speech.rust.bailian.apiKey")
  let legacy=RustProductSettingsClient.legacySnapshot(defaults)
  precondition(!legacy.keys.contains(where:{$0.lowercased().contains("key")}))
  let secrets=Secrets(),prefs=RustSpeechPreferences(defaults:defaults,settings:client,secrets:secrets)
  precondition(secrets.reads==0 && secrets.markerReads==0 && secrets.imported.isEmpty)
  _ = prefs.configuration(for:"tts",includesEnvironment:false,includesSecrets:false)
  precondition(secrets.reads==0 && secrets.markerReads==0 && prefs.credentialConfigured(provider:.bailian)==nil)
  precondition(prefs.configuration(for:"tts",includesEnvironment:false).apiKey=="inert-old")
  precondition(secrets.imported==Set(["bailian"]))
  let fileRoot=FileManager.default.temporaryDirectory.appendingPathComponent("speech-file-fixture-"+UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:fileRoot)}
  let fileSecrets=FileSpeechSecretStore(directory:fileRoot)
  precondition(!FileManager.default.fileExists(atPath:fileRoot.path))
  try fileSecrets.write(provider:"bailian",key:"inert-private-file")
  precondition(fileSecrets.read(provider:"bailian")=="inert-private-file")
  let dirMode=try FileManager.default.attributesOfItem(atPath:fileRoot.path)[.posixPermissions] as? NSNumber
  let fileMode=try FileManager.default.attributesOfItem(atPath:fileRoot.appendingPathComponent("speech-bailian.key").path)[.posixPermissions] as? NSNumber
  precondition(dirMode?.intValue==0o700 && fileMode?.intValue==0o600)
  try fileSecrets.write(provider:"bailian",key:"inert-replaced")
  precondition(fileSecrets.read(provider:"bailian")=="inert-replaced")
  do{try fileSecrets.write(provider:"../outside",key:"inert");fatalError("provider traversal accepted")}catch{}
  let outside=fileRoot.appendingPathComponent("outside")
  try Data("inert-outside".utf8).write(to:outside)
  try FileManager.default.createSymbolicLink(at:fileRoot.appendingPathComponent("speech-fish.key"),withDestinationURL:outside)
  precondition(fileSecrets.read(provider:"fish")==nil)
  do{try fileSecrets.write(provider:"fish",key:"inert");fatalError("symlink accepted")}catch{}
  let retained=try String(contentsOf:outside,encoding:.utf8);precondition(retained=="inert-outside")
  try await client.reload()
  precondition(client.confirmed?.values.backgroundTurnsPerHour==0)
  let before=client.confirmed!.revision
  let result=try await client.apply(["locale":"en","residentPersona":"new"])
  precondition(result.revision==before+1 && client.confirmed?.values.locale=="en")
  try await prefs.save(.init(provider:.bailian,apiKey:"inert-new",voiceID:"Cherry",model:"fixture-new"),for:"tts")
  precondition(secrets.keys["bailian"]=="inert-new")
  rpc.denied(true)
  do {try await prefs.save(.init(provider:.bailian,apiKey:"inert-rejected",voiceID:"Cherry",model:"bad"),for:"tts");fatalError("accepted failure")}catch{}
  precondition(secrets.keys["bailian"]=="inert-new" && client.confirmed?.values.ttsModel=="fixture-new")
  precondition(defaults.string(forKey:"resident.persona.v1")=="legacy")
  rpc.denied(false)
  let orb=OrbAppearance(red:1.7,green:-0.4,blue:0.48,flowIntensity:2.3)
  let confirmedOrb=try await orb.save(to:defaults,settings:client)
  precondition(confirmedOrb.red==1 && confirmedOrb.green==0 && confirmedOrb.blue==0.48 && confirmedOrb.flowIntensity==1.5)
  precondition(defaults.object(forKey:"orb.appearance.red")==nil)
  rpc.denied(true)
  do {_=try await OrbAppearance.default.save(to:defaults,settings:client);fatalError("accepted orb failure")}catch{}
  precondition(OrbAppearance.load(from:defaults,settings:client)==confirmedOrb)
  let bridge=UnityResidentAgentLoopBridge(context:WorldAgentContext(),defaults:defaults,settings:client,
      available:{true},run:{_ in "inert"},cancelRun:{},onReply:{_ in})
  let attempts=rpc.count();bridge.resumeByUser()
  while rpc.count()==attempts {await Task.yield()}
  for _ in 0..<100 {await Task.yield()}
  precondition(bridge.loop.resumes==0 && !bridge.ambientEnabled)
  rpc.denied(false);bridge.resumeByUser()
  while !bridge.ambientEnabled || bridge.loop.resumes==0 {await Task.yield()}
  precondition(bridge.loop.resumes==1)
  bridge.pauseByUser()
  while bridge.ambientEnabled {await Task.yield()}
  precondition(defaults.object(forKey:UnityResidentAgentLoopBridge.enabledKey)==nil)
  bridge.close()
  let shortcuts=GMGNShortcutSettingsStore(defaults:defaults,settings:client)
  let combinationData=try JSONEncoder().encode(shortcuts.assignment(for:.togglePlayback).global)
  let combinationObject=try JSONSerialization.jsonObject(with:combinationData) as! [String:Any]
  precondition(combinationObject["modifiers"] as? Int==3)
  let shortcutCalls=rpc.count();shortcuts.globalEnabled=false
  precondition(shortcuts.globalEnabled) // Candidate cannot update the native hotkeys before confirmation.
  while shortcuts.globalEnabled{await Task.yield()}
  precondition(rpc.count()>shortcutCalls && defaults.object(forKey:"gmgn.keyboardShortcuts.globalEnabled")==nil)
  rpc.denied(true);let denied=rpc.count();shortcuts.mediaKeysEnabled=false
  while rpc.count()==denied{await Task.yield()};while shortcuts.settingsError==nil{await Task.yield()}
  precondition(shortcuts.mediaKeysEnabled && defaults.object(forKey:"gmgn.keyboardShortcuts.mediaKeysEnabled")==nil)
  rpc.denied(false)
  let auth=MusicAccountCommandService(),accounts=MusicAccountsModel(service:auth,defaults:defaults,settings:client)
  await accounts.load();let receipts=rpc.receiptCount();auth.fails=true
  await accounts.connect(.netease)
  precondition(rpc.receiptCount()==receipts && accounts.neteaseState == .disconnected)
  auth.fails=false;await accounts.connect(.netease)
  precondition(auth.authenticated && accounts.neteaseState == .connected && client.confirmed?.values.musicConnectedProviders==["netease"])
  precondition(defaults.object(forKey:"music.connected-provider-ids")==nil)
  await accounts.disconnect(.netease)
  precondition(!auth.authenticated && accounts.neteaseState == .disconnected && client.confirmed?.values.musicConnectedProviders==[])
  let host=BackendHostFixture(client,"codex")
  rpc.holdNextBackend();var backendCompleted=false
  let changing=Task{@MainActor in let result=await host.command(["op":"agent.backend","id":"dsh"]);backendCompleted=true;return result}
  while !rpc.waitingBackend(){await Task.yield()}
  precondition(!backendCompleted && host.chat.backend=="codex" && host.chat.cancellations==0)
  rpc.releaseBackend();let changed=await changing.value
  precondition(changed && host.chat.backend=="dsh" && client.confirmed?.values.agentBackend=="dsh" && host.chat.cancellations==1)
  let writes=rpc.backendWriteCount(),cancelCount=host.chat.cancellations
  let sameBackend=await host.command(["op":"agent.backend","id":"dsh"])
  precondition(sameBackend && rpc.backendWriteCount()==writes && host.chat.cancellations==cancelCount)
  rpc.denied(true);let rejectedBackend=await host.command(["op":"agent.backend","id":"codex"])
  precondition(!rejectedBackend && host.chat.backend=="dsh" && client.confirmed?.values.agentBackend=="dsh")
  rpc.denied(false);rpc.loseNextBackendReceipt()
  let recoveredBackend=await host.command(["op":"agent.backend","id":"codex"])
  precondition(recoveredBackend && host.chat.backend=="codex" && client.confirmed?.values.agentBackend=="codex")
  precondition(rpc.backendWriteCount()==writes+1) // Readback recovered the receipt; no mutation replay.
  host.closed=true;let closedBackend=await host.command(["op":"agent.backend","id":"dsh"])
  precondition(!closedBackend && rpc.backendWriteCount()==writes+1)
  _ = try await client.apply(["autonomyEnabled":false])
  let wishes=WishMachineTaskPresentationStore(productSettings:client,legacyDefaults:defaults)
  wishes.update([.init(id:UUID(),title:"private-wish",status:"paused",detail:nil,isTerminal:false,autoContinuationPaused:true)])
  var resumedWishes=0;wishes.onResumeAutomaticContinuation={_ in resumedWishes+=1}
  rpc.denied(true);wishes.resumeAutonomy()
  while wishes.autonomyResumeFailure==nil{await Task.yield()}
  precondition(resumedWishes==0 && !wishes.isAutonomySwitchOn)
  rpc.denied(false);wishes.resumeAutonomy()
  while resumedWishes==0{await Task.yield()}
  precondition(resumedWishes==1 && wishes.isAutonomySwitchOn && wishes.autonomyResumeFailure==nil)
  let inboxRPC=InertInboxRPC(),inboxClient=RustInboxClient(call:inboxRPC.call)
  let inbox=ResidentSystemInboxStore(client:inboxClient)
  let delivery=ResidentSystemDelivery(eventID:"event",taskID:"task",kind:"wish",title:"confirmed",status:"completed",detail:"detail",terminal:true)
  inboxRPC.fail=true;let notSaved=await inbox.apply(delivery,worldID:"private-world",residentScope:"private-scope")
  precondition(!notSaved && inbox.entries(worldID:"private-world",residentScope:"private-scope").isEmpty && inbox.persistenceError != nil)
  let unknownID=inboxRPC.ids.last!
  inboxRPC.fail=false;inboxRPC.revision=1;inboxRPC.unread=1;inboxRPC.changed=true
  let anchor=Date(timeIntervalSince1970:100.125)
  inboxRPC.entries=[.init(taskKey:"task",lastEventID:"event",kind:"wish",title:"confirmed",status:"completed",detail:"detail",terminal:true,isRead:false,readAt:nil,deliveredAt:anchor,updatedAt:anchor)]
  inboxRPC.expiries=["task":anchor.addingTimeInterval(30)]
  let saved=await inbox.apply(delivery,worldID:"private-world",residentScope:"private-scope")
  precondition(saved && inboxRPC.ids.last==unknownID && inbox.unreadCount(worldID:"private-world",residentScope:"private-scope")==1)
  precondition(inbox.visibleEntries(worldID:"private-world",residentScope:"private-scope",now:anchor.addingTimeInterval(29)).count==1)
  precondition(inbox.visibleEntries(worldID:"private-world",residentScope:"private-scope",now:anchor.addingTimeInterval(31)).isEmpty)
  inboxRPC.revision=2;inboxRPC.unread=0;inboxRPC.entries[0].isRead=true;inboxRPC.entries[0].readAt=anchor.addingTimeInterval(5)
  let read=await inbox.markRead(taskKey:"task",worldID:"private-world",residentScope:"private-scope",expectedEventID:"event")
  precondition(read && inbox.unreadCount(worldID:"private-world",residentScope:"private-scope")==0 && inbox.entry(taskKey:"task",worldID:"private-world",residentScope:"private-scope")?.updatedAt==anchor)
  precondition(!inboxRPC.requests.contains("state_commit"))
  print("PASS: confirmed settings, zero budget, credential rollback and production autonomy raw events")
 }
}
"""##.write(to: main, atomically: true, encoding: .utf8)
let binary=work.appendingPathComponent("test"),compile=Process()
compile.executableURL=URL(fileURLWithPath:"/usr/bin/swiftc")
compile.arguments=["-swift-version","6","-j1","-parse-as-library",extracted.path,
 shortcuts.path,
 hostFixture.path,
 root.appendingPathComponent("apps/macos/UnityHost/UnityAgentConnectionBridge.swift").path,
 root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/WishMachineTaskPresentation.swift").path,
 root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentStateClient.swift").path,
 root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentSystemInbox.swift").path,
 root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/RustInboxClient.swift").path,
 root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Settings/MusicAccountsModel.swift").path,
 root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/RustProductSettingsClient.swift").path,
 root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ProductSpeechSecretStore.swift").path,
 root.appendingPathComponent("apps/macos/UnityHost/UnityResidentAgentLoopBridge.swift").path,
 root.appendingPathComponent("apps/macos/Sources/GMGNRadio/VisualEngine/OrbAppearance.swift").path,
 main.path,"-o",binary.path]
try compile.run();compile.waitUntilExit();guard compile.terminationStatus==0 else{exit(compile.terminationStatus)}
let run=Process();run.executableURL=binary;try run.run();run.waitUntilExit();exit(run.terminationStatus)
