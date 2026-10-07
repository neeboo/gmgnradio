import Foundation

// Production settings must use the same isolated service root for both catalog
// and preview; replacing either with a default client recreates the UI failure.
let settingsSource = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/Settings/AgentSettingsView.swift", encoding: .utf8)
func settingsVoiceRootIsIsolated(_ source: String) -> Bool {
    source.contains("RustVoiceClient(root: E2ERuntime.productSupportDirectory()")
        && source.contains(".appendingPathComponent(\"TaskService\", isDirectory: true)")
        && source.contains("voiceClient.listVoices(configuration: configuration)")
        && source.contains("statusStore: previewStatus, client: voiceClient)")
        && source.contains("preview?.stopSpeaking(); preview = nil\n        previewStatus.lastErrorMessage = nil")
        && !source.contains("RustVoiceClient().listVoices")
        && !source.contains("voiceID = result.first")
}
guard settingsVoiceRootIsIsolated(settingsSource),
      !settingsVoiceRootIsIsolated(settingsSource.replacingOccurrences(of: "root: E2ERuntime.productSupportDirectory()", with: "root: FileManager.default.temporaryDirectory")),
      !settingsVoiceRootIsIsolated(settingsSource.replacingOccurrences(of: "voiceClient.listVoices", with: "RustVoiceClient().listVoices")),
      !settingsVoiceRootIsIsolated(settingsSource.replacingOccurrences(of: "previewStatus.lastErrorMessage = nil", with: "/* stale preview error retained */")),
      !settingsVoiceRootIsIsolated(settingsSource + "\nvoiceID = result.first?.id ?? \"\""),
      !settingsVoiceRootIsIsolated(settingsSource.replacingOccurrences(of: "statusStore: previewStatus, client: voiceClient)", with: "statusStore: previewStatus)")) else {
    fatalError("settings isolated voice root wiring or negative controls failed")
}
print("PASS: settings isolated-root wiring, stale-error reset and explicit voice selection with five negative controls")
func modelsUseRustContract(_ source: String) -> Bool {
    source.contains("Picker(\"模型\", selection: $model)")
        && source.contains("voiceClient.capabilities()")
        && source.contains("if model.isEmpty { model = defaultModelID ?? \"\" }")
        && source.contains(".disabled(!modelSelectionIsValid)")
        && !source.contains("TextField(\"模型")
}
guard modelsUseRustContract(settingsSource),
      !modelsUseRustContract(settingsSource.replacingOccurrences(of: "voiceClient.capabilities()", with: "localHardcodedModelList()")),
      !modelsUseRustContract(settingsSource + "\nTextField(\"模型\", text: $model)") else {
    fatalError("Rust model contract picker wiring or negative controls failed")
}
print("PASS: Rust-owned model picker wiring with two negative controls")

// This harness exercises TTS and endpoint validation only. It never starts ASR,
// recording, an audio device, or the application.
let fixture = #"""
import threading,json,os,sys,uuid
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
path,marker=sys.argv[1:];token=str(uuid.uuid4());connections=0
with open(marker,'w') as f:f.write('0')
class Handler(BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*args):pass
 def do_GET(self):
  assert self.path=='/health' and self.headers.get('Authorization')=='Bearer '+token
  raw=json.dumps({'version':2,'transport':'http'}).encode()
  self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
 def do_POST(self):
  global connections
  connections+=1
  with open(marker,'w') as f:f.write(str(connections))
  q=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  assert self.headers.get('Authorization')=='Bearer '+token and 'auth' not in q
  key=q['params'].get('apiKey')
  if key=='http-status':
   raw=json.dumps({'error':{'code':'http_fixture_rejected','message':'never expose provider detail'}}).encode()
   self.send_response(403);self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw);return
  if key=='wrong-media':
   self.send_response(200);self.send_header('Content-Type','text/plain');self.send_header('Connection','close');self.end_headers();return
  if key=='oversize-event':
   self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Connection','close');self.end_headers()
   self.wfile.write(b'data: '+b'x'*262145+b'\n\n');self.wfile.flush();return
  if self.path=='/events':
   self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Connection','close');self.end_headers()
  def send(o):
   raw=json.dumps(o).encode()
   if self.path=='/events':self.wfile.write(b'data: '+raw+b'\n\n');self.wfile.flush()
   else:
    self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
  for q in [q]:
   if q['method']=='voice_capabilities':
    caps={'version':1,'providers':[{'id':'fish','ttsModels':[{'id':'s2.1-pro-free','name':'S2.1 Pro · 免费'},{'id':'s2-pro','name':'S2 Pro · 付费'}],'asrModels':[],'defaultTTSModel':'s2.1-pro-free','defaultASRModel':None}]}
    send({'id':q['id'],'result':caps});continue
   if q['method']=='voice_list':
    p=q['params'];key=p['apiKey'];voices=[{'id':'v1','name':'自然女声'},{'id':'v2','name':'清晰男声'}]
    provider=p['provider']
    if key=='duplicate':voices[1]['id']='v1'
    if key=='empty-name':voices[0]['name']=''
    if key=='wrong-provider':provider='fish'
    if key=='too-many':voices=[{'id':str(i),'name':'声线'} for i in range(201)]
    reply={'id':q['id'],'result':{'provider':provider,'voices':voices}}
    if key=='provider-failure':reply={'id':q['id'],'error':{'code':'voice_provider_error'}}
    send(reply);continue
   assert q['method']=='voice_tts_start'
   if q['params'].get('text','').startswith('custom-'):
    assert q['params']['voiceID']=='custom_voice_id'
    assert q['params']['text']=='custom-'+q['params']['provider']
    assert q['params']['model'] in ['qwen3-tts-vc-realtime-2026-01-15','eleven_flash_v2_5','s2.1-pro-free']
   sid=q['params']['sessionID']
   for reply in [{'id':q['id'],'result':{'started':True,'sessionID':sid}}, {'voice_event':{'sessionID':sid,'type':'finished'}}]:
    send(reply)

server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
with open(path,'w') as f:json.dump({'version':2,'address':'127.0.0.1:'+str(server.server_port),'token':token},f)
os.chmod(path,0o600);server.serve_forever()
"""#
let program = #"""
import Foundation
@main struct Checks {
 @MainActor static func main() async throws {
  let endpoint=URL(fileURLWithPath:CommandLine.arguments[1]),marker=URL(fileURLWithPath:CommandLine.arguments[2])
  let root=endpoint.deletingLastPathComponent(),manager=FileManager.default
  let original=try Data(contentsOf:endpoint)
  var checks=0
  func check(_ ok:Bool,_ message:String) {guard ok else {fatalError(message)};checks+=1}
  let valid=RustVoiceClient(root:root,endpointURL:endpoint,allowsLaunching:false)
  let session=try await valid.startTTS(text:"valid",configuration:.init(apiKey:"fixture-memory-only"))
  let event=try await session.nextEvent()
  check(event.type=="finished","private owner-only endpoint connects")
  session.close()
  for (provider,model) in [(RustVoiceProvider.bailian,"qwen3-tts-vc-realtime-2026-01-15"),(.elevenlabs,"eleven_flash_v2_5"),(.fish,"s2.1-pro-free")] {
   let custom=try await valid.startTTS(text:"custom-"+provider.rawValue,configuration:.init(provider:provider,apiKey:"fixture-memory-only",voiceID:"custom_voice_id",model:model))
   let finished=try await custom.nextEvent()
   check(finished.type=="finished","custom voice and selected model forwarded unchanged through Swift RPC")
   custom.close()
  }
  let listed=try await valid.listVoices(configuration:.init(provider:.elevenlabs,apiKey:"fixture-memory-only"))
  check(listed.map(\.id)==["v1","v2"] && listed[0].name=="自然女声","voice names decoded through authenticated Rust RPC")
  for key in ["duplicate","empty-name","wrong-provider","too-many"] {
   do {_ = try await valid.listVoices(configuration:.init(provider:.elevenlabs,apiKey:key));fatalError("malformed voice catalog accepted")}
   catch RustVoiceError.invalidFrame {check(true,"malformed voice catalog rejected")}
  }
  do {_ = try await valid.listVoices(configuration:.init(provider:.elevenlabs,apiKey:"provider-failure"));fatalError("provider failure accepted")}
  catch RustVoiceError.rejected {check(true,"provider failure surfaced without remote error text")}
  let capabilities=try await valid.capabilities()
  check(capabilities.providers[0].defaultTTSModel=="s2.1-pro-free" && capabilities.providers[0].ttsModels.count==2,"models and default read from authenticated Rust metadata RPC without API key")
  do {_ = try await valid.startTTS(text:"reject",configuration:.init(apiKey:"http-status"));fatalError("HTTP failure accepted")}
  catch RustVoiceError.rejected(let code) {check(code=="http_fixture_rejected","HTTP error preserves safe code only")}
  for key in ["wrong-media","oversize-event"] {
   do {_ = try await valid.startTTS(text:"reject",configuration:.init(apiKey:key));fatalError("invalid SSE accepted")}
   catch RustVoiceError.invalidFrame {check(true,"SSE MIME and bounded event validation")}
  }
  let initial=try String(contentsOf:marker,encoding:.utf8)
  check(initial=="14","four TTS and six catalog plus metadata and three HTTP failures connect independently")
  let link=root.appendingPathComponent("linked.endpoint.json")
  try manager.createSymbolicLink(at:link,withDestinationURL:endpoint)
  let large=root.appendingPathComponent("large.endpoint.json")
  var oversized=original;oversized.append(Data(repeating:32,count:65537))
  try oversized.write(to:large)
  try manager.setAttributes([.posixPermissions:0o600],ofItemAtPath:large.path)
  let publicFile=root.appendingPathComponent("public.endpoint.json")
  try original.write(to:publicFile)
  try manager.setAttributes([.posixPermissions:0o644],ofItemAtPath:publicFile.path)
  let directory=root.appendingPathComponent("directory.endpoint.json",isDirectory:true)
  try manager.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
  let oldEndpoint=root.appendingPathComponent("v1.endpoint.json")
  var old=try JSONSerialization.jsonObject(with:original) as! [String:Any];old["version"]=1
  try JSONSerialization.data(withJSONObject:old).write(to:oldEndpoint)
  try manager.setAttributes([.posixPermissions:0o600],ofItemAtPath:oldEndpoint.path)
  for unsafe in [link,large,publicFile,directory,oldEndpoint] {
   let client=RustVoiceClient(root:root,endpointURL:unsafe,allowsLaunching:false)
   do {_ = try await client.startTTS(text:"reject",configuration:.init(apiKey:"must-never-be-sent"));fatalError("unsafe endpoint accepted")}
   catch RustVoiceError.invalidFrame {check(true,"unsafe endpoint rejected before transport")}
   catch {fatalError("unexpected error classification")}
  }
  try await Task.sleep(for:.milliseconds(100))
  check(try String(contentsOf:marker,encoding:.utf8)==initial,"unsafe descriptors establish no connection and send no credential")
  print("PASS: \(checks) safe endpoint TTS-only checks; ASR and capture not run")
 }
}
"""#
let scratch=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-safe-voice-endpoint-"+UUID().uuidString)
try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
defer {try? FileManager.default.removeItem(at:scratch)}
let driver=scratch.appendingPathComponent("main.swift"),binary=scratch.appendingPathComponent("checks"),endpoint=scratch.appendingPathComponent("taskd.endpoint.json"),marker=scratch.appendingPathComponent("connections")
try program.write(to:driver,atomically:true,encoding:.utf8)
let build=Process();build.executableURL=URL(fileURLWithPath:"/usr/bin/env")
build.arguments=["swiftc","-swift-version","6","-parse-as-library","apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift","apps/macos/Sources/GMGNRadio/Agent/RustVoiceClient.swift",driver.path,"-o",binary.path]
try build.run();build.waitUntilExit();guard build.terminationStatus==0 else {exit(build.terminationStatus)}
let server=Process();server.executableURL=URL(fileURLWithPath:"/usr/bin/python3");server.arguments=["-u","-c",fixture,endpoint.path,marker.path]
server.standardOutput=FileHandle.nullDevice
try server.run();defer {server.terminate();server.waitUntilExit()}
let deadline=Date().addingTimeInterval(5)
while !FileManager.default.fileExists(atPath:marker.path) {guard Date()<deadline else {fatalError("fixture startup timeout")};Thread.sleep(forTimeInterval:0.01)}
let checks=Process();checks.executableURL=binary;checks.arguments=[endpoint.path,marker.path]
try checks.run();checks.waitUntilExit();exit(checks.terminationStatus)
