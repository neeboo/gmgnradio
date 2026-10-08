#!/usr/bin/env python3
"""Production Unity registrar + actual GLB sampler + private HTTP authority fixture."""
from pathlib import Path
import hashlib, json, os, struct, subprocess, tempfile, threading, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
repo=Path(__file__).resolve().parents[3]
source=(repo/"apps/macos/UnityHost/UnityWishMachineBridge.swift").read_text()
registrar=source[source.index("@MainActor final class UnityWishInventoryRegistrar"):]
token=str(uuid.uuid4());wish=str(uuid.uuid4()).upper();methods=[];registered=False
positions=[[-.1,0,-.1],[.1,0,-.1],[.1,.2,-.1],[-.1,.2,-.1],[-.1,0,.1],[.1,0,.1],[.1,.2,.1],[-.1,.2,.1]]
indices=[0,2,1,0,3,2,4,5,6,4,6,7,0,1,5,0,5,4,3,7,6,3,6,2,0,4,7,0,7,3,1,2,6,1,6,5]
raw=b''.join(struct.pack('<fff',*p) for p in positions)+struct.pack('<36H',*indices)
gltf={"asset":{"version":"2.0"},"buffers":[{"byteLength":len(raw)}],"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":96},{"buffer":0,"byteOffset":96,"byteLength":72}],"accessors":[{"bufferView":0,"componentType":5126,"count":8,"type":"VEC3"},{"bufferView":1,"componentType":5123,"count":36,"type":"SCALAR"}],"meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}],"nodes":[{"mesh":0}],"scenes":[{"nodes":[0]}],"scene":0}
j=json.dumps(gltf,separators=(',',':')).encode();j+=b' '*((-len(j))%4);raw+=b'\0'*((-len(raw))%4)
glb=struct.pack('<4sII',b'glTF',2,12+8+len(j)+8+len(raw))+struct.pack('<I4s',len(j),b'JSON')+j+struct.pack('<I4s',len(raw),b'BIN\0')+raw
digest=hashlib.sha256(glb).hexdigest()
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*_):pass
 def do_POST(self):
  global registered
  assert self.headers['Authorization']=='Bearer '+token
  w=json.loads(self.rfile.read(int(self.headers['Content-Length'])));m,p=w['method'],w['params'];methods.append(m)
  state=json.loads((fixture_root/'state.json').read_text())
  prop={"objectID":"actual-output","sourceWishID":wish,"assetID":"sha256:"+digest,"displayName":"Rust measured output","sourceHeight":.2,"size":{"x":.7,"y":.8,"z":.9}}
  if registered:state['objectStates']={'actual-output':{"isEnabled":False,"transform":{"position":{"x":0,"y":0,"z":0},"rotation":{"x":0,"y":0,"z":0,"w":1},"scale":{"x":1,"y":1,"z":1}},"metadata":{"gmgn.generated-prop.v1":json.dumps(prop)}}};state['layoutRevision']=4
  if m=='world_blob_put':
   assert p['localPath']==str(fixture_root/'actual.glb') and p['sha256']==digest;result={"stored":True}
  elif m=='world_snapshot':result={"record":{"recordRevision":8 if registered else 7,"state":state}}
  elif m=='world_prop_system_avatar_return':
   assert p['worldID']=='actual-world' and p['residentScope']=='actual-resident' and p['hostSessionID']=='actual-session'
   assert p['expectedRevision']==8 and p['expectedLayoutRevision']==4 and p['geometryID']=='actual-new-avatar-geometry'
   assert p['event']=={'kind':'avatar_changed_rebind','objectID':'actual-output','previousAvatarAssetID':'old-avatar','avatarAssetID':'loaded-new-avatar','selectionRevision':2,'heldBindingSHA256':'actual-durable-held-hash'}
   assert 'candidate' not in p and 'authority' not in p and 'command' not in p and 'state' not in p
   result={'receipt':{'op':'hold'},'snapshot':{'record':{'recordRevision':9,'state':state}}}
  else:
   assert m=='world_prop_register' and p['worldID']=='actual-world' and p['residentScope']=='actual-resident' and p['hostSessionID']=='actual-session'
   assert p['wishID']==wish and p['expectedRevision']==7 and p['expectedLayoutRevision']==3
   assert set(p['measurement'])=={'blobRef','triangles'} and p['measurement']['blobRef']=='sha256:'+digest and len(p['measurement']['triangles'])==12
   assert 'size' not in p and 'orientation' not in p and 'state' not in p and 'authority' not in p
   registered=True;state['layoutRevision']=4
   state['objectStates']={'actual-output':{"isEnabled":False,"transform":{"position":{"x":0,"y":0,"z":0},"rotation":{"x":0,"y":0,"z":0,"w":1},"scale":{"x":1,"y":1,"z":1}},"metadata":{"gmgn.generated-prop.v1":json.dumps(prop)}}}
   result={"receipt":{"op":"register"},"commit":{"revision":8},"snapshot":{"record":{"recordRevision":8,"state":state}}}
  b=json.dumps({"id":w['id'],"result":result}).encode();self.send_response(200);self.send_header('Content-Length',str(len(b)));self.end_headers();self.wfile.write(b)
swift=r'''
import Foundation
import CryptoKit
import WorldRuntime
enum WishMachineError:Error {case notReady,unavailable,conflictingCall}
struct WorldAuthorityEndpoint {let endpointFile:String;init(applicationSupportBase:URL){endpointFile=applicationSupportBase.appendingPathComponent("endpoint.json").path}}
struct WishMachineJob {enum Stage {case claimed,ready};let id:UUID;let worldID:String;let residentScope:String;let objectID:String;let jobID:String?;let modelPath:String?;var stage:Stage}
struct PropGenerationRecord {struct Receipt {enum State {case completed};struct Result {struct Inspection {let sha256:String;let bytes:Int};let inspection:Inspection};let state:State;let result:Result?};let id:String;let receipt:Receipt?;let localModelPath:String?;let localCollisionPath:String?}
@MainActor final class PropGenerationStore {var jobs:[PropGenerationRecord];init(_ jobs:[PropGenerationRecord]){self.jobs=jobs}}
__REGISTRAR__
@main struct Fixture {
 @MainActor static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),wish=UUID(uuidString:CommandLine.arguments[2])!,hash=CommandLine.arguments[3]
  var state=WorldState(revision:1,worldID:"actual-world",worldTime:Date(timeIntervalSince1970:0),lastObservedWallTime:Date(timeIntervalSince1970:0),weather:.clear,agentTransform:WorldTransform(position:.init(x:0,y:0,z:0),rotation:.init(x:0,y:0,z:0,w:1),scale:.init(x:1,y:1,z:1)));state.layoutRevision=3
  let encoder=JSONEncoder();encoder.dateEncodingStrategy = .millisecondsSince1970;try encoder.encode(state).write(to:root.appendingPathComponent("state.json"))
  let path=root.appendingPathComponent("actual.glb").path,bytes=try Data(contentsOf:URL(fileURLWithPath:path)).count
  let store=PropGenerationStore([.init(id:"actual-generation",receipt:.init(state:.completed,result:.init(inspection:.init(sha256:hash,bytes:bytes))),localModelPath:path,localCollisionPath:nil)])
  let registrar=UnityWishInventoryRegistrar(root:root,worldID:"actual-world",residentScope:"actual-resident",hostSessionID:"actual-session",store:store)
  let job=WishMachineJob(id:wish,worldID:"actual-world",residentScope:"actual-resident",objectID:"actual-output",jobID:"actual-generation",modelPath:path,stage:.claimed)
  let result=try await registrar.register(job)
  assert(result.size == .init(x:0.7,y:0.8,z:0.9) && result.assetID == "sha256:"+hash)
  let durable=try await registrar.readback(objectID:"actual-output");assert(durable==result)
  var unclaimed=job;unclaimed.stage = .ready
  do {_ = try await registrar.register(unclaimed);fatalError("unclaimed registration sent")} catch WishMachineError.notReady {}
  let client=RustWorldPropClient(endpointFile:root.appendingPathComponent("endpoint.json"))
  _ = try await client.systemAvatarReturn(.init(worldID:"actual-world",residentScope:"actual-resident",hostSessionID:"actual-session"),expectedRevision:8,layoutRevision:4,geometryID:"actual-new-avatar-geometry",requestID:"actual-system-rebind",objectID:"actual-output",previousAvatarAssetID:"old-avatar",avatarAssetID:"loaded-new-avatar",selectionRevision:2,heldBindingSHA256:"actual-durable-held-hash",rebind:true)
  print("PASS production Unity registrar: verified actual GLB -> raw triangles/blob -> Rust register -> durable inventory; no Swift size/orientation/world writer")
 }
}
'''.replace('__REGISTRAR__',registrar)
with tempfile.TemporaryDirectory(prefix='gmgn-private-inventory-') as directory:
 fixture_root=Path(directory);(fixture_root/'actual.glb').write_bytes(glb)
 server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
 endpoint=fixture_root/'endpoint.json';endpoint.write_text(json.dumps({"version":2,"address":"127.0.0.1:"+str(server.server_port),"token":token}));os.chmod(endpoint,0o600)
 generated=fixture_root/'fixture.swift';generated.write_text(swift)
 flags=subprocess.check_output(['bash','tools/world-runtime-harness-flags.sh'],cwd=repo,text=True).splitlines();binary=fixture_root/'fixture'
 subprocess.run(['swiftc','-swift-version','6','-parse-as-library',*flags,str(repo/'apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift'),str(repo/'apps/macos/Sources/GMGNRadio/Presence/RustWorldPropClient.swift'),str(repo/'apps/macos/Sources/GMGNRadio/Presence/RustPropNativeMeshSampler.swift'),str(generated),'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(fixture_root),wish,digest],check=True)
 assert methods==['world_blob_put','world_snapshot','world_prop_register','world_snapshot','world_snapshot','world_prop_system_avatar_return']
 server.shutdown()
