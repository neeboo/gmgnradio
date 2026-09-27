import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = ["PropGenerationClient", "PropImagePreparation", "PropGenerationStore", "PropTaskDaemonClient"].map {
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/\($0).swift").path
}
let fixture = #"""
import socket,threading,json,os,time,sys,uuid
root,path=sys.argv[1:]
server=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);server.bind(path);os.chmod(path,0o600);server.listen()
lock=threading.RLock(); jobs={};events=[]; messages={};acks=set();connections=[];subscriptions=[];snapshots={};seq=0;msgseq=0
def send(c,value):
 try:
  with lock: c.sendall((json.dumps(value)+'\n').encode())
 except OSError: pass
def event(job):
 global seq
 with lock:
  seq+=1;e={'sequence':seq,'job':dict(job)};events.append(e)
  for c in connections: send(c,{'event':e})
def handle(c,q):
 global msgseq
 p=q['params'];m=q['method'];r={}
 if m=='configure': r={'configured':True}
 elif m=='snapshot':
  with lock:
   if p.get('cursor'):
    rows,version=snapshots.pop(p['cursor'])
    if os.path.exists(root+'/inconsistent'):version+=1
   else:
    rows,version=[dict(j) for j in jobs.values()],seq
    if os.path.exists(root+'/large'):
     sample=rows[0];rows=[]
     for index in range(13):
      item=dict(sample,id=str(uuid.uuid4()).upper())
      item['receipt']={'id':'a'*32,'state':'running','reason':'x'*1000000,'name':'cup','source':sample['source'],'height_meters':.2,'compute_may_continue':False,'created_at':1,'updated_at':2}
      rows.append(item)
   r={'jobs':rows[:1],'sequence':version}
   if len(rows)>1:
    cursor=str(uuid.uuid4());snapshots[cursor]=(rows[1:],version);r['nextCursor']=cursor
 elif m=='subscribe':
  with lock:
   send(c,{'id':q['id'],'result':{'subscribed':True}})
   for e in events:
    if e['sequence']>p['after']:send(c,{'event':e})
   connections.append(c)
  return
 elif m=='submit':
  j={'id':p['id'],'name':p['name'],'endpoint':p['endpoint'],'imagePath':root+'/image.png','imageSHA256':'a'*64,'heightMeters':p['heightMeters'],'source':p['source'],'idempotencyKey':p['id'],'backendStage':'queued','cancelRequested':False,'context':p.get('context')}
  queued=dict(j);jobs[j['id']]=j;event(j)
  time.sleep(.18)
  j=dict(j);j['backendStage']='running';jobs[j['id']]=j;event(j)
  time.sleep(.18);r={'job':queued}
 elif m=='retry':
  if os.path.exists(root+'/hang'):return
  if os.path.exists(root+'/reject'):
   send(c,{'id':q['id'],'error':{'code':'fixture_reject','message':'fixture-secret-only-memory'}});return
  r={'job':jobs[p['id']]}
 elif m=='cancel':
  j=dict(jobs[p['id']]);j['cancelRequested']=True;j['backendStage']='cancel_requested';jobs[p['id']]=j;event(j);r={'job':j}
 elif m=='publish_message':
  with lock:
   if p['id'] not in messages:
    msgseq+=1;messages[p['id']]=dict(p,sequence=msgseq)
   r={'message':messages[p['id']]}
   for conn,s in subscriptions:
    if (s['worldID'],s['residentScope'])==(p['worldID'],p['residentScope']) and (p['id'],s['consumer']) not in acks:send(conn,r)
 elif m=='subscribe_messages':
  with lock:
   subscriptions.append((c,p));send(c,{'id':q['id'],'result':{'subscribed':True}})
   for v in messages.values():
    if (p['worldID'],p['residentScope'])==(v['worldID'],v['residentScope']) and (v['id'],p['consumer']) not in acks:send(c,{'message':v})
  return
 elif m=='ack_message':
  acks.add((p['id'],p['consumer']));r={'acknowledged':True}
 else: send(c,{'id':q['id'],'error':{'code':'unknown','message':'secret must not escape'}});return
 send(c,{'id':q['id'],'result':r})
def serve(c):
 try:
  for line in c.makefile('rb'):
   q=json.loads(line);threading.Thread(target=handle,args=(c,q),daemon=True).start()
 except (OSError,ValueError):pass
def drop():
 while True:
  time.sleep(.02)
  marker=root+'/drop'
  if os.path.exists(marker):
   os.unlink(marker)
   with lock:
    for c in set(connections+[x[0] for x in subscriptions]):
     try:c.shutdown(socket.SHUT_RDWR)
     except OSError:pass
     c.close()
    connections.clear();subscriptions.clear()
threading.Thread(target=drop,daemon=True).start()
while True:
 c,_=server.accept();threading.Thread(target=serve,args=(c,),daemon=True).start()
"""#
let program = #"""
import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

@main struct Checks {
 @MainActor static func main() async throws {
  var checks=0
  func check(_ value: Bool,_ label: String) { guard value else { fatalError("FAIL: "+label) }; checks+=1 }
  func until(_ label:String,_ predicate: @MainActor () -> Bool) async throws {
   let deadline=Date().addingTimeInterval(6)
   while !predicate() { guard Date()<deadline else { fatalError("FAIL timeout: "+label) }; try await Task.sleep(for:.milliseconds(20)) }
  }
  let scratch=URL(fileURLWithPath:"/tmp/gmgn-ipc-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  defer { try? FileManager.default.removeItem(at:scratch) }
  let socket=scratch.appendingPathComponent("taskd.sock")
  let server=Process();server.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
  server.arguments=["-u","-c",try String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8),scratch.path,socket.path]
  server.standardOutput=FileHandle.nullDevice
  try server.run();defer { server.terminate();server.waitUntilExit() }
  try await until("fixture socket") { FileManager.default.fileExists(atPath:socket.path) }
  let client=PropTaskDaemonClient(root:scratch,socketURL:socket,allowsLaunching:false,requestTimeout:2)
  let normalized=try PropTaskDaemonClient.normalizedEndpoint(URL(string:"https://EXAMPLE.COM:443/")!)
  check(normalized.absoluteString=="https://example.com","origin normalization matches Rust for slash, case, and default port")
  defer { client.disconnect() }
  let store=PropGenerationStore(directory:scratch,daemonClient:client)
  var changes=0;store.onChange={changes+=1}
  var messages:[String:[PropTaskMessage]]=[:]
  store.onMessage={consumer,message in messages[consumer,default:[]].append(message)}
  try store.configure(endpoint:URL(string:"http://127.0.0.1:8765")!,token:"fixture-secret-only-memory")
  await store.refreshSnapshot()
  check(store.jobs.isEmpty,"empty daemon snapshot")
  let pixels=Data(repeating:255,count:16)
  let provider=CGDataProvider(data:pixels as CFData)!
  let image=CGImage(width:2,height:2,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:8,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
  let imageURL=scratch.appendingPathComponent("input.png")
  let dest=CGImageDestinationCreateWithURL(imageURL as CFURL,UTType.png.identifier as CFString,1,nil)!
  CGImageDestinationAddImage(dest,image,nil);check(CGImageDestinationFinalize(dest),"fixture PNG")
  let changedID=UUID()
  let preparing=Task { await store.create(imageURL:imageURL,name:"changed",author:"me",license:"own",heightMeters:0.2,id:changedID) }
  for _ in 0..<10000 { if store.isBusy { break }; await Task.yield() }
  check(store.isBusy,"image preparation is in flight")
  try store.configure(endpoint:URL(string:"https://replacement.example")!,token:"replacement")
  let changed=await preparing.value
  check(changed==nil && !store.jobs.contains(where:{$0.id==changedID}),"configuration change during image preparation prevents submission")
  try store.configure(endpoint:URL(string:"http://127.0.0.1:8765")!,token:"fixture-secret-only-memory")
  let cancelledID=UUID()
  let preparingCancellation=Task { await store.create(imageURL:imageURL,name:"cancel preparation",author:"me",license:"own",heightMeters:0.2,id:cancelledID) }
  for _ in 0..<10000 { if store.isBusy { break }; await Task.yield() }
  preparingCancellation.cancel()
  let cancelledPreparation=await preparingCancellation.value
  check(cancelledPreparation==nil && !store.jobs.contains(where:{$0.id==cancelledID}),"cancelled preparation never reaches daemon submit")
  let id1=UUID(),id2=UUID()
  var accepted1:UUID?,accepted2:UUID?
  let context=PropTaskContext(worldID:"world-fixture",residentScope:"resident-fixture")
  let first=Task { accepted1=await store.create(imageURL:imageURL,name:"cup",author:"me",license:"own",heightMeters:0.2,id:id1,context:context) }
  let second=Task { accepted2=await store.create(imageURL:imageURL,name:"plant",author:"me",license:"own",heightMeters:0.3,id:id2,context:context) }
  try await until("two jobs concurrently queued") { store.jobs.count==2 }
  check(accepted1==nil && accepted2==nil,"no acceptance before durable ACK")
  try store.configure(endpoint:URL(string:"https://replacement.example")!,token:"replacement")
  await store.cancel(id:id2)
  check(store.jobs.first(where:{$0.id==id2})?.cancelRequested==true,"busy submission does not block cancellation")
  await first.value;await second.value
  check(accepted1==id1 && accepted2==id2,"distinct jobs both accepted")
  check(store.jobs.allSatisfy{$0.endpoint==URL(string:"http://127.0.0.1:8765")!},"in-flight ACK remains bound to original service after configuration changes")
  await store.retrySubmission(id:id1)
  check(store.errorMessage==PropGenerationError.providerChanged.localizedDescription,"provider change cannot retry a different origin job")
  do { try store.configure(endpoint:URL(string:"http://unsafe.example")!,token:"invalid") } catch {}
  let invalidID=UUID()
  let invalidConfiguration=await store.create(imageURL:imageURL,name:"invalid",author:"me",license:"own",heightMeters:0.2,id:invalidID)
  check(invalidConfiguration==nil && !store.jobs.contains(where:{$0.id==invalidID}),"invalid replacement does not retain previous submission credentials")
  try store.configure(endpoint:URL(string:"http://127.0.0.1:8765")!,token:"fixture-secret-only-memory")
  store.clearConfiguration()
  let cleared=await store.create(imageURL:imageURL,name:"cleared",author:"me",license:"own",heightMeters:0.2)
  check(cleared==nil,"cleared configuration prevents new submission")
  try store.configure(endpoint:URL(string:"http://127.0.0.1:8765")!,token:"fixture-secret-only-memory")
  check(store.jobs.first(where:{$0.id==id1})?.backendStage=="running","late queued ACK cannot regress newer running event")
  check(store.jobs.first(where:{$0.id==id1})?.context==context,"scope carried unchanged")
  check(!FileManager.default.fileExists(atPath:scratch.appendingPathComponent("tasks.json").path),"Swift facade never writes legacy task history")
  check(!store.isBusy && changes>=4,"event projection releases busy state and notifies")
  await store.refreshSnapshot()
  check(store.jobs.count==2,"snapshot pages are assembled before replacing the projection")
  let duplicate=await store.create(imageURL:imageURL,name:"cup",author:"me",license:"own",heightMeters:0.2,id:id1,context:context)
  check(duplicate==nil && store.jobs.count==2,"existing UUID cannot create another facade task")
  try Data().write(to:scratch.appendingPathComponent("hang"))
  let held=Task { try await client.retry(id:id1) }
  try await Task.sleep(for:.milliseconds(50));held.cancel()
  do { _ = try await held.value;fatalError("FAIL cancelled IPC request accepted") }
  catch is CancellationError { checks+=1 }
  do { _ = try await client.retry(id:id1);fatalError("FAIL unbounded IPC request") }
  catch PropTaskDaemonError.timedOut { checks+=1 }
  try FileManager.default.removeItem(at:scratch.appendingPathComponent("hang"))
  try Data().write(to:scratch.appendingPathComponent("reject"))
  do { _ = try await client.retry(id:id1);fatalError("FAIL rejected IPC request accepted") }
  catch { check(!error.localizedDescription.contains("fixture-secret"),"daemon error bodies never leak credentials into UI") }
  try FileManager.default.removeItem(at:scratch.appendingPathComponent("reject"))
  for consumer in ["world","ui","agent"] { try await store.subscribeMessages(consumer:consumer,worldID:context.worldID,residentScope:context.residentScope) }
  let messageID=UUID()
  _ = try await store.publishMessage(id:messageID,taskId:id1,worldID:context.worldID,residentScope:context.residentScope,kind:"wish.outputReady",payload:["name":.string("cup")])
  try await until("three independent consumer callbacks") { ["world","ui","agent"].allSatisfy{messages[$0]?.contains(where:{$0.id==messageID})==true} }
  check(Set(messages.keys)==Set(["world","ui","agent"]),"message carries exact consumer identity")
  try await store.acknowledgeMessage(id:messageID,consumer:"ui",worldID:context.worldID,residentScope:context.residentScope)
  let uiBefore=messages["ui"]!.count,agentBefore=messages["agent"]!.count,worldBefore=messages["world"]!.count
  try Data().write(to:scratch.appendingPathComponent("drop"))
  try await until("unacked agent and world replay after socket loss") { messages["agent"]!.count>agentBefore && messages["world"]!.count>worldBefore }
  check(messages["ui"]!.count==uiBefore,"UI ACK never consumes world or agent inbox")
  store.unsubscribeMessages(consumer:"agent",worldID:context.worldID,residentScope:context.residentScope)
  let unsubscribed=messages["agent"]!.count
  _ = try await store.publishMessage(id:UUID(),taskId:id1,worldID:context.worldID,residentScope:context.residentScope,kind:"wish.claimed",payload:[:])
  try await Task.sleep(for:.milliseconds(150))
  check(messages["agent"]!.count==unsubscribed,"scope unsubscribe stops its connection")
  try Data().write(to:scratch.appendingPathComponent("large"))
  let large=try await client.snapshot()
  let largeBytes=try JSONEncoder().encode(large).count
  check(large.jobs.count==13 && largeBytes>12*1024*1024,"thirteen near-1MiB receipts cross the frame limit through bounded snapshot pages")
  try FileManager.default.removeItem(at:scratch.appendingPathComponent("large"))
  try Data().write(to:scratch.appendingPathComponent("inconsistent"))
  await store.refreshSnapshot()
  check(store.jobs.count==13 && store.errorMessage != nil,"mixed-sequence pages never partially overwrite the current projection")
  try FileManager.default.removeItem(at:scratch.appendingPathComponent("inconsistent"))
  let missing=PropTaskDaemonClient(root:scratch.appendingPathComponent("missing"),helperURL:scratch.appendingPathComponent("no-helper"))
  do { _ = try await missing.snapshot();fatalError("FAIL missing helper accepted") }
  catch PropTaskDaemonError.helperMissing { checks+=1 }
  missing.disconnect()
  if CommandLine.arguments.count > 2 {
   let realRoot=scratch.appendingPathComponent("rust")
   let realSocket=realRoot.appendingPathComponent("taskd.sock")
   let legacy=scratch.appendingPathComponent("legacy")
   try FileManager.default.createDirectory(at:legacy,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
   let legacyPNG=legacy.appendingPathComponent("input.png")
   let png=try Data(contentsOf:imageURL);try png.write(to:legacyPNG)
   let pngHash=SHA256.hash(data:png).map{String(format:"%02x",$0)}.joined()
   let legacySource=PropGenerationSource(author:"fixture",license:"own")
   let legacyJobs=(0..<13).map { index in
    let id=UUID()
    let receipt=PropGenerationReceipt(id:String(format:"%032x",index+1),state:.interrupted,reason:String(repeating:"x",count:1000000),name:"legacy",source:legacySource,heightMeters:0.2,result:nil,computeMayContinue:false,createdAt:1,updatedAt:2)
    return PropGenerationRecord(id:id,name:"legacy",endpoint:URL(string:"http://127.0.0.1:1")!,imagePath:legacyPNG.path,imageSHA256:pngHash,heightMeters:0.2,source:legacySource,idempotencyKey:id.uuidString,receipt:receipt)
   }
   let legacyData=try JSONEncoder().encode(legacyJobs)
   try legacyData.write(to:legacy.appendingPathComponent("tasks.json"))
   let process=Process();process.executableURL=URL(fileURLWithPath:CommandLine.arguments[2])
   process.arguments=["--root",realRoot.path,"--socket",realSocket.path,"--concurrency","2","--legacy-root",legacy.path]
   process.standardOutput=FileHandle.nullDevice
   try process.run();defer { process.terminate();process.waitUntilExit() }
   try await until("real Rust fixture socket") { FileManager.default.fileExists(atPath:realSocket.path) }
   let real=PropTaskDaemonClient(root:realRoot,socketURL:realSocket,allowsLaunching:false)
   let migrated=try await real.snapshot()
   let migratedBytes=try JSONEncoder().encode(migrated).count
   check(migrated.jobs.count==13 && migratedBytes>12*1024*1024,"real Rust fixed-sequence pagination carries more than 12MiB through Swift")
   let unchangedLegacy=try Data(contentsOf:legacy.appendingPathComponent("tasks.json"))
   check(unchangedLegacy==legacyData,"real Rust import leaves original legacy history unchanged")
   var realEvents:[PropTaskDaemonEvent]=[];real.onEvent={realEvents.append($0)}
   let identity=UUID(),endpoint=URL(string:"http://127.0.0.1:1")!
   let record=try await real.submit(id:identity,endpoint:endpoint,name:"real fixture",png:png,source:PropGenerationSource(author:"fixture",license:"own"),heightMeters:0.2,context:context)
   check(record.id==identity && record.idempotencyKey==identity.uuidString,"real Rust durable ACK preserves identity")
   check(FileManager.default.isReadableFile(atPath:record.imagePath),"real Rust persists PNG before ACK")
   let same=try await real.submit(id:identity,endpoint:endpoint,name:"real fixture",png:png,source:PropGenerationSource(author:"fixture",license:"own"),heightMeters:0.2,context:context)
   check(same.id==record.id,"real Rust idempotent resubmit remains one task")
   real.disconnect()
   let resumed=PropTaskDaemonClient(root:realRoot,socketURL:realSocket,allowsLaunching:false)
   defer { resumed.disconnect() }
   let restored=try await resumed.snapshot()
   check(restored.jobs.count==14 && restored.jobs.contains(where:{$0.id==identity}),"real Rust retains jobs after Swift disconnect")
   let cancel=try await resumed.cancel(id:identity)
   check(cancel.cancelRequested==true || cancel.backendStage=="cancelled","real Rust stores cancellation without configured remote credentials")
   var deliveries:[String:Int]=[:];resumed.onMessage={consumer,_ in deliveries[consumer,default:0]+=1}
   for consumer in ["world","ui","agent"] { try await resumed.subscribeMessages(consumer:consumer,worldID:context.worldID,residentScope:context.residentScope) }
   _ = try await resumed.publishMessage(id:UUID(),taskId:identity,worldID:context.worldID,residentScope:context.residentScope,kind:"wish.cancelled",payload:["fixture":.bool(true)])
   try await until("real Rust messages to three consumers") { ["world","ui","agent"].allSatisfy{deliveries[$0,default:0]>0} }
   check(deliveries.count==3,"real Rust message wire schema compatible")
   check(!realEvents.isEmpty,"real Rust event wire schema compatible")
  }
  print("PASS: \(checks) Swift daemon facade/socket/message checks")
 }
}
"""#
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-taskd-client-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let main = temp.appendingPathComponent("Checks.swift"), python = temp.appendingPathComponent("fixture.py")
try program.write(to: main, atomically: true, encoding: .utf8)
try fixture.write(to: python, atomically: true, encoding: .utf8)
let binary = temp.appendingPathComponent("checks")
let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
compiler.arguments = ["swiftc", "-swift-version", "6", "-parse-as-library"] + sources + [main.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(1) }
let run = Process(); run.executableURL = binary; run.arguments = [python.path] + Array(CommandLine.arguments.dropFirst())
try run.run(); run.waitUntilExit(); exit(run.terminationStatus)
