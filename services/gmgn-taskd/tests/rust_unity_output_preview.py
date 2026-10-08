#!/usr/bin/env python3
"""Production ready-output catalog, real mesh decode and private HTTP authority."""
from pathlib import Path
import hashlib,json,os,struct,subprocess,tempfile,threading,uuid
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
repo=Path(__file__).resolve().parents[3]
token=str(uuid.uuid4()); job=str(uuid.uuid4()); wish=str(uuid.uuid4()); calls=[]
vertices=[[-.1,0,-.1],[.1,0,-.1],[.1,.2,.1],[-.1,.2,.1]]
raw=struct.pack('<12f',*(v for p in vertices for v in p))+struct.pack('<6H',0,1,2,0,2,3)
j=json.dumps({'asset':{'version':'2.0'},'buffers':[{'byteLength':len(raw)}],'bufferViews':[{'buffer':0,'byteOffset':0,'byteLength':48},{'buffer':0,'byteOffset':48,'byteLength':12}],'accessors':[{'bufferView':0,'componentType':5126,'count':4,'type':'VEC3'},{'bufferView':1,'componentType':5123,'count':6,'type':'SCALAR'}],'meshes':[{'primitives':[{'attributes':{'POSITION':0},'indices':1}]}],'nodes':[{'mesh':0}],'scenes':[{'nodes':[0]}],'scene':0},separators=(',',':')).encode()
j+=b' '*((-len(j))%4);glb=struct.pack('<4sII',b'glTF',2,28+len(j)+len(raw))+struct.pack('<I4s',len(j),b'JSON')+j+struct.pack('<I4s',len(raw),b'BIN\0')+raw
digest=hashlib.sha256(glb).hexdigest()
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*_):pass
 def do_POST(self):
  assert self.headers['Authorization']=='Bearer '+token
  w=json.loads(self.rfile.read(int(self.headers['Content-Length'])));m,p=w['method'],w['params'];calls.append(m)
  if m=='world_blob_put':assert p['sha256']==digest;result={}
  elif m=='world_snapshot':result={'record':{'recordRevision':7,'state':json.loads((root/'state.json').read_text())}}
  else:
   assert m=='world_prop_output_preview' and p['hostSessionID']=='actual-control-session' and p['wishID']==wish.upper()
   assert p['measurement']['blobRef']==digest and len(p['measurement']['triangles'])==2
   assert not {'candidate','size','orientation','authority','state'} & p.keys()
   result={'prop':{'objectID':'actual-output','sourceWishID':wish.upper(),'assetID':'sha256:'+digest,'displayName':'Rust projection','sourceHeight':.2,'size':{'x':.7,'y':.8,'z':.9}}}
  b=json.dumps({'id':w['id'],'result':result}).encode();self.send_response(200);self.send_header('Content-Length',str(len(b)));self.end_headers();self.wfile.write(b)
swift=r'''
import Foundation
import WorldRuntime
enum WishMachineError:Error {case unavailable}
struct WishMachineJob:Codable {enum Stage:String,Codable{case ready,claimed};let id:UUID;let worldID:String;let residentScope:String;let jobID:UUID?;let modelPath:String?;let stage:Stage}
struct PropGenerationRecord:Codable {struct Context:Codable{let worldID:String;let residentScope:String};struct Receipt:Codable{enum State:String,Codable{case completed};struct Result:Codable{struct Inspection:Codable{let sha256:String;let bytes:Int};let inspection:Inspection?};let state:State;let result:Result?};let id:UUID;let context:Context?;let receipt:Receipt?;let localModelPath:String?;let localCollisionPath:String?}
__CATALOG__
@main struct Fixture {
 @MainActor static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),job=UUID(uuidString:CommandLine.arguments[2])!,wish=UUID(uuidString:CommandLine.arguments[3])!,hash=CommandLine.arguments[4]
  var state=WorldState(revision:1,worldID:"actual-world",worldTime:Date(timeIntervalSince1970:0),lastObservedWallTime:Date(timeIntervalSince1970:0),weather:.clear,agentTransform:WorldTransform(position:.init(x:0,y:0,z:0),rotation:.init(x:0,y:0,z:0,w:1),scale:.init(x:1,y:1,z:1)));state.layoutRevision=3
  let enc=JSONEncoder();enc.dateEncodingStrategy = .millisecondsSince1970;try enc.encode(state).write(to:root.appendingPathComponent("state.json"))
  let path=root.appendingPathComponent("gmgn radio/TaskService/"+job.uuidString.lowercased()+".glb").path
  let record=PropGenerationRecord(id:job,context:.init(worldID:"actual-world",residentScope:"actual-resident"),receipt:.init(state:.completed,result:.init(inspection:.init(sha256:hash,bytes:try Data(contentsOf:URL(fileURLWithPath:path)).count))),localModelPath:path,localCollisionPath:nil)
  let catalog=UnityWishOutputPreviewCatalog(root:root,worldID:"actual-world",residentScope:"actual-resident",projectionSessionID:UUID().uuidString,hostSessionID:"actual-control-session")
  catalog.update(wishes:[.init(id:wish,worldID:"actual-world",residentScope:"actual-resident",jobID:job,modelPath:path,stage:.ready)],jobs:[record])
  for _ in 0..<100 {if (catalog.snapshot()["entries"] as? [[String:Any]])?.isEmpty == false {break};try await Task.sleep(for:.milliseconds(10))}
  guard let entry=(catalog.snapshot()["entries"] as! [[String:Any]]).first else {fatalError("missing preview: \(catalog.snapshot())")};assert((entry["size"] as! [String:Double])["x"]==0.7)
  assert(entry["stage"] as? String == "ready" && entry["localModelPath"] as? String == path)
  catalog.update(wishes:[.init(id:wish,worldID:"actual-world",residentScope:"actual-resident",jobID:job,modelPath:path,stage:.claimed)],jobs:[record])
  try await Task.sleep(for:.milliseconds(30));assert((catalog.snapshot()["entries"] as! [[String:Any]]).isEmpty)
  catalog.update(wishes:[.init(id:wish,worldID:"actual-world",residentScope:"actual-resident",jobID:job,modelPath:"/invalid.glb",stage:.ready)],jobs:[record])
  try await Task.sleep(for:.milliseconds(30));assert((catalog.snapshot()["errors"] as! [[String:String]]).first?["code"] == "wish_output_asset_unverified")
  catalog.close();print("PASS production ready preview: actual GLB/raw measurement -> Rust read-only projection; no claim/register")
 }
}
'''.replace('__CATALOG__',(repo/'apps/macos/UnityHost/UnityWishOutputPreviewCatalog.swift').read_text().replace('import Foundation','').replace('import CryptoKit','').replace('import WorldRuntime',''))
swift=swift.replace('import Foundation','import Foundation\nimport CryptoKit',1)
with tempfile.TemporaryDirectory(prefix='gmgn-output-preview-',dir='/private/tmp') as directory:
 root=Path(directory);task=root/'gmgn radio/TaskService';task.mkdir(parents=True);(task/(job.lower()+'.glb')).write_bytes(glb)
 server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
 ep=task/'endpoint.json';ep.write_text(json.dumps({'version':2,'address':'127.0.0.1:'+str(server.server_port),'token':token}));os.chmod(ep,0o600)
 src=root/'fixture.swift';src.write_text(swift);binary=root/'fixture'
 flags=subprocess.check_output(['bash','tools/world-runtime-harness-flags.sh'],cwd=repo,text=True).splitlines()
 subprocess.run(['swiftc','-swift-version','6','-parse-as-library',*flags,*[str(repo/'apps/macos/Sources/GMGNRadio/Presence'/name) for name in ['TaskdHTTPTransport.swift','RustWorldPropClient.swift','RustPropNativeMeshSampler.swift']],str(src),'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(root),job,wish,digest],check=True)
 assert calls==['world_blob_put','world_snapshot','world_prop_output_preview'];server.shutdown()
