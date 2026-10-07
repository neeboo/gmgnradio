import Foundation

let fixture = #"""
import threading,json,os,sys,uuid,base64,time,queue
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
path=sys.argv[1];token=str(uuid.uuid4());sessions={};lock=threading.Lock()
class Handler(BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*args):pass
 def do_GET(self):
  assert self.path=='/health' and self.headers.get('Authorization')=='Bearer '+token
  raw=json.dumps({'version':2,'transport':'http'}).encode()
  self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
 def do_POST(self):
  q=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  assert self.headers.get('Authorization')=='Bearer '+token and 'auth' not in q
  p=q['params'];m=q['method'];i=q['id'];client=self.headers.get('X-GMGN-Client-ID')
  assert isinstance(i,str) and client
  def send(o):
   raw=json.dumps(o).encode()
   if self.path=='/events':self.wfile.write(b'data: '+raw+b'\n\n');self.wfile.flush()
   else:
    self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
  try:
   if self.path=='/events':
    assert m in ['voice_tts_start','voice_asr_start']
    sid=p['sessionID'];uuid.UUID(sid);events=queue.Queue()
    with lock:sessions[client]=(sid,events)
    self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Connection','close');self.end_headers()
    send({'id':i,'result':{'started':True,'sessionID':sid}})
    if p.get('text')=='drop':return
    if m=='voice_tts_start':
     if p.get('text')=='burst':
      for index in range(64):send({'voice_event':{'sessionID':sid,'type':'audio','audioBase64':base64.b64encode(bytes([index,0])*16384).decode(),'sampleRate':24000,'channels':1,'encoding':'pcm16le'}})
      send({'voice_event':{'sessionID':sid,'type':'finished'}});return
     for chunk in [bytes([255]),bytes([127,0,128])]:send({'voice_event':{'sessionID':sid,'type':'audio','audioBase64':base64.b64encode(chunk).decode(),'sampleRate':24000,'channels':1,'encoding':'pcm16le'}})
     send({'voice_event':{'sessionID':sid,'type':'finished'}});return
    if p.get('voiceID')=='never-ready':time.sleep(2);return
    if p.get('voiceID')=='ready-error':send({'voice_event':{'sessionID':sid,'type':'error','code':'voice_provider_error'}});return
    time.sleep(.15);send({'voice_event':{'sessionID':sid,'type':'ready'}})
    while True:
     event=events.get(timeout=3);send({'voice_event':dict(sessionID=sid,**event)})
     if event['type']=='finished':return
   else:
    sid,events=sessions[client];assert p['sessionID']==sid
    if m=='voice_audio_append':
     pcm=base64.b64decode(p['audioBase64']);assert len(pcm)%2==0 and len(pcm)<=32768
     send({'id':i,'result':{'accepted':True}});events.put({'type':'partial','text':'hello'})
    elif m=='voice_asr_commit':
     send({'id':i,'result':{'committed':True}});events.put({'type':'final','text':'hello world'});events.put({'type':'finished'})
    else:assert False
  except (OSError,ValueError,queue.Empty):pass
  finally:
   if self.path=='/events':
    with lock:sessions.pop(client,None)
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
with open(path,'w') as f:json.dump({'version':2,'address':'127.0.0.1:'+str(server.server_port),'token':token},f)
os.chmod(path,0o600);server.serve_forever()
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
  let burst=try await client.startTTS(text:"burst",configuration:.init(apiKey:"fixture-memory-only"))
  try await Task.sleep(for:.milliseconds(150))
  for index in 0..<64 {
   let event=try await burst.nextEvent()
   check(event.type=="audio" && Data(base64Encoded:event.audioBase64!)==Data(Array(repeating:[UInt8(index),UInt8(0)],count:16384).flatMap{$0}),"fast synthesis survives slow PCM consumption losslessly")
   try await Task.sleep(for:.milliseconds(10))
  }
  check(try await burst.nextEvent().type=="finished","burst terminal is retained behind audio")
  burst.close()
  let blocked=try await client.startTTS(text:"burst",configuration:.init(apiKey:"fixture-memory-only"))
  try await Task.sleep(for:.milliseconds(150))
  let cancelStarted=Date();blocked.close()
  do {_ = try await blocked.nextEvent();fatalError("cancelled burst returned queued PCM")}
  catch {check(error is CancellationError && Date().timeIntervalSince(cancelStarted)<1,"cancellation releases producer pressure and discards buffered PCM")}
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
build.arguments=["swiftc","-swift-version","6","-parse-as-library","apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift","apps/macos/Sources/GMGNRadio/Agent/RustVoiceClient.swift",driver.path,"-o",binary.path]
try build.run();build.waitUntilExit();guard build.terminationStatus==0 else {exit(build.terminationStatus)}
let server=Process();server.executableURL=URL(fileURLWithPath:"/usr/bin/python3");server.arguments=["-u","-c",fixture,endpoint.path]
server.standardOutput=FileHandle.nullDevice
try server.run();defer {server.terminate();server.waitUntilExit()}
let deadline=Date().addingTimeInterval(5)
while !FileManager.default.fileExists(atPath:endpoint.path) {guard Date()<deadline else {fatalError("fixture startup timeout")};Thread.sleep(forTimeInterval:0.01)}
let checks=Process();checks.executableURL=binary;checks.arguments=[endpoint.path]
try checks.run();checks.waitUntilExit();exit(checks.terminationStatus)
