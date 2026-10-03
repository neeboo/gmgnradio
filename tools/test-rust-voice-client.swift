import Foundation

let fixture = #"""
import socket,threading,json,os,sys,uuid,base64,time
path=sys.argv[1]; token=str(uuid.uuid4())
server=socket.socket(socket.AF_INET,socket.SOCK_STREAM);server.bind(('127.0.0.1',0));server.listen()
with open(path,'w') as f:json.dump({'version':1,'address':'127.0.0.1:'+str(server.getsockname()[1]),'token':token},f)
os.chmod(path,0o600)
def serve(c):
 def send(o):c.sendall((json.dumps(o)+'\n').encode())
 sid=None
 try:
  for line in c.makefile('rb'):
   q=json.loads(line)
   if q.get('auth')!=token:send({'id':q.get('id'),'error':{'code':'unauthorized'}});return
   p=q['params']; m=q['method']; i=q['id']
   if not isinstance(i,str):raise ValueError('id must be string')
   if m in ['voice_tts_start','voice_asr_start']:
    sid=p['sessionID'];uuid.UUID(sid)
    send({'id':i,'result':{'started':True,'sessionID':sid}})
    if p.get('text')=='drop':return
    if m=='voice_asr_start':
     if p.get('voiceID')=='never-ready':time.sleep(2);return
     if p.get('voiceID')=='ready-error':send({'voice_event':{'sessionID':sid,'type':'error','code':'voice_provider_error'}});return
     time.sleep(.15)
     try:
      early=c.recv(1,socket.MSG_PEEK|socket.MSG_DONTWAIT)
      if early:raise ValueError('audio sent before cloud readiness')
     except BlockingIOError:pass
     send({'voice_event':{'sessionID':sid,'type':'ready'}})
    if m=='voice_tts_start':
     for chunk in [bytes([255]),bytes([127,0,128])]:
      send({'voice_event':{'sessionID':sid,'type':'audio','audioBase64':base64.b64encode(chunk).decode(),'sampleRate':24000,'channels':1,'encoding':'pcm16le'}})
     send({'voice_event':{'sessionID':sid,'type':'finished'}})
   elif m=='voice_audio_append':
    assert p['sessionID']==sid
    pcm=base64.b64decode(p['audioBase64']);assert len(pcm)%2==0 and len(pcm)<=32768
    send({'id':i,'result':{'accepted':True}})
    send({'voice_event':{'sessionID':sid,'type':'partial','text':'hello'}})
   elif m=='voice_asr_commit':
    assert p['sessionID']==sid
    send({'id':i,'result':{'committed':True}})
    send({'voice_event':{'sessionID':sid,'type':'final','text':'hello world'}})
    send({'voice_event':{'sessionID':sid,'type':'finished'}})
   elif m=='voice_cancel':return
 except (OSError,ValueError):pass
 finally:c.close()
while True:
 c,_=server.accept();threading.Thread(target=serve,args=(c,),daemon=True).start()
"""#
let program = #"""
import Foundation
@main struct Checks {
 @MainActor static func main() async throws {
  let endpoint = URL(fileURLWithPath: CommandLine.arguments[1])
  var checks=0
  func check(_ ok:Bool,_ message:String) { guard ok else {fatalError(message)};checks+=1 }
  let client=RustVoiceClient(root:endpoint.deletingLastPathComponent(),endpointURL:endpoint,allowsLaunching:false)
  let tts=try await client.startTTS(text:"fixture",configuration:.init(apiKey:"fixture-memory-only"))
  let a=try await tts.nextEvent(),b=try await tts.nextEvent(),end=try await tts.nextEvent()
  check(a.type=="audio" && b.type=="audio" && end.type=="finished","bounded audio events arrive in order")
  check(a.sessionID==tts.sessionID && a.sampleRate==24000 && a.channels==1 && a.encoding=="pcm16le","session and format")
  check(Data(base64Encoded:a.audioBase64!)==Data([255]) && Data(base64Encoded:b.audioBase64!)==Data([127,0,128]),"odd chunk remains lossless")
  tts.close()
  let dropped=try await client.startTTS(text:"drop",configuration:.init(apiKey:"fixture"))
  do {_ = try await dropped.nextEvent();fatalError("closed provider accepted")}
  catch {check(!(error is CancellationError),"remote failure must not masquerade as user cancellation")}
  dropped.close()
  let readyStarted=Date()
  let asr=try await client.startASR(configuration:.init(provider:.elevenlabs,apiKey:"fixture-memory-only",voiceID:""))
  check(Date().timeIntervalSince(readyStarted)>=0.14,"ASR waits cloud readiness before returning capture session")
  try await asr.sendAudio(Data([0,0,1,0]))
  let partial=try await asr.nextEvent()
  check(partial.type=="partial" && partial.text=="hello","append acknowledgement skipped for partial")
  do {try await asr.sendAudio(Data([1]));fatalError("odd ASR input accepted")} catch {check(true,"odd ASR sample rejected")}
  do {try await asr.sendAudio(Data(repeating:0,count:32770));fatalError("oversized ASR input accepted")} catch {check(true,"oversized ASR chunk rejected")}
  try await asr.commit()
  let final=try await asr.nextEvent(),finished=try await asr.nextEvent()
  check(final.type=="final" && final.text=="hello world" && finished.type=="finished","manual commit final transcript")
  asr.cancel()
  do {_ = try await asr.nextEvent();fatalError("cancelled stream read")} catch {check(true,"close interrupts read")}
  let timeoutStarted=Date()
  do {_ = try await client.startASR(configuration:.init(apiKey:"fixture",voiceID:"never-ready"),readyTimeout:0.1);fatalError("missing ready accepted")}
  catch {check(Date().timeIntervalSince(timeoutStarted)<1,"readiness timeout is finite and closes pending read")}
  do {_ = try await client.startASR(configuration:.init(apiKey:"fixture",voiceID:"ready-error"));fatalError("provider error accepted")}
  catch {check(error is RustVoiceError,"readiness provider error is propagated")}
  let cancellation=Task {try await client.startASR(configuration:.init(apiKey:"fixture",voiceID:"never-ready"))}
  try await Task.sleep(for:.milliseconds(50));cancellation.cancel()
  do {_ = try await cancellation.value;fatalError("cancelled readiness accepted")}
  catch {check(error is CancellationError,"readiness cancellation interrupts connection")}
  let original=try Data(contentsOf:endpoint)
  defer {try? original.write(to:endpoint)}
  for (key,value) in [("address","192.168.1.1:1234"),("address","127.0.0.1:0"),("token","invalid")] {
   var document=try JSONSerialization.jsonObject(with:original) as! [String:Any]
   document[key]=value
   try JSONSerialization.data(withJSONObject:document).write(to:endpoint)
   do {_ = try await client.startTTS(text:"reject",configuration:.init(apiKey:"fixture"));fatalError("invalid endpoint accepted")}
   catch {check(true,"invalid endpoint refused before connecting")}
  }
  print("PASS: \(checks) production authenticated loopback voice client checks")
 }
}
"""#
let scratch=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-voice-client-tests-"+UUID().uuidString)
try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
defer {try? FileManager.default.removeItem(at:scratch)}
let driver=scratch.appendingPathComponent("main.swift"),binary=scratch.appendingPathComponent("checks"),endpoint=scratch.appendingPathComponent("taskd.endpoint.json")
try program.write(to:driver,atomically:true,encoding:.utf8)
let build=Process();build.executableURL=URL(fileURLWithPath:"/usr/bin/env")
build.arguments=["swiftc","-swift-version","6","-parse-as-library","apps/macos/Sources/GMGNRadio/Agent/RustVoiceClient.swift",driver.path,"-o",binary.path]
try build.run();build.waitUntilExit();guard build.terminationStatus==0 else {exit(build.terminationStatus)}
let server=Process();server.executableURL=URL(fileURLWithPath:"/usr/bin/python3");server.arguments=["-u","-c",fixture,endpoint.path]
server.standardOutput=FileHandle.nullDevice
try server.run();defer {server.terminate();server.waitUntilExit()}
let deadline=Date().addingTimeInterval(5)
while !FileManager.default.fileExists(atPath:endpoint.path) {guard Date()<deadline else {fatalError("fixture startup timeout")};Thread.sleep(forTimeInterval:0.01)}
let checks=Process();checks.executableURL=binary;checks.arguments=[endpoint.path]
try checks.run();checks.waitUntilExit();exit(checks.terminationStatus)
