import Foundation

// This harness exercises TTS and endpoint validation only. It never starts ASR,
// recording, an audio device, or the application.
let fixture = #"""
import socket,threading,json,os,sys,uuid
path,marker=sys.argv[1:];token=str(uuid.uuid4());connections=0
server=socket.socket(socket.AF_INET,socket.SOCK_STREAM);server.bind(('127.0.0.1',0));server.listen()
with open(path,'w') as f:json.dump({'version':1,'address':'127.0.0.1:'+str(server.getsockname()[1]),'token':token},f)
os.chmod(path,0o600)
with open(marker,'w') as f:f.write('0')
def serve(c):
 try:
  for line in c.makefile('rb'):
   q=json.loads(line)
   assert q.get('auth')==token and q['method']=='voice_tts_start'
   sid=q['params']['sessionID']
   for reply in [{'id':q['id'],'result':{'started':True,'sessionID':sid}}, {'voice_event':{'sessionID':sid,'type':'finished'}}]:
    c.sendall((json.dumps(reply)+'\n').encode())
 except (OSError,ValueError):pass
 finally:c.close()
while True:
 c,_=server.accept();connections+=1
 with open(marker,'w') as f:f.write(str(connections))
 threading.Thread(target=serve,args=(c,),daemon=True).start()
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
  let initial=try String(contentsOf:marker,encoding:.utf8)
  check(initial=="1","one baseline connection")
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
  for unsafe in [link,large,publicFile,directory] {
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
build.arguments=["swiftc","-swift-version","6","-parse-as-library","apps/macos/Sources/GMGNRadio/Agent/RustVoiceClient.swift",driver.path,"-o",binary.path]
try build.run();build.waitUntilExit();guard build.terminationStatus==0 else {exit(build.terminationStatus)}
let server=Process();server.executableURL=URL(fileURLWithPath:"/usr/bin/python3");server.arguments=["-u","-c",fixture,endpoint.path,marker.path]
server.standardOutput=FileHandle.nullDevice
try server.run();defer {server.terminate();server.waitUntilExit()}
let deadline=Date().addingTimeInterval(5)
while !FileManager.default.fileExists(atPath:marker.path) {guard Date()<deadline else {fatalError("fixture startup timeout")};Thread.sleep(forTimeInterval:0.01)}
let checks=Process();checks.executableURL=binary;checks.arguments=[endpoint.path,marker.path]
try checks.run();checks.waitUntilExit();exit(checks.terminationStatus)
