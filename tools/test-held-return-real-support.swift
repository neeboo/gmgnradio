import Foundation

// Opt-in acceptance against the current locally running app. The only formal
// RPC is world_snapshot; all mutations use MemoryOnly and never write credentials
// or the authority snapshot to disk. Run while the test sword is actually held.

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let service = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentPropPlacementService.swift"), encoding: .utf8)
func declaration(_ signature: String,source:String = service) -> String {
    let start = source.range(of: signature)!.lowerBound
    let open = source[start...].firstIndex(of: "{")!
    var depth = 0
    for index in source[open...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]).replacingOccurrences(of: "private static func", with: "static func") }
    }
    fatalError("Unbalanced production declaration")
}
let attachment = try String(contentsOf:root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/PropAttachment.swift"),encoding:.utf8)
let pointStart = attachment.range(of:"enum PropAttachmentPoint:")!.lowerBound
let pointOpen = attachment[pointStart...].firstIndex(of:"{")!
var pointDepth=0,pointEnd=pointOpen
for index in attachment[pointOpen...].indices {
    if attachment[index] == "{" {pointDepth += 1}; if attachment[index] == "}" {pointDepth -= 1}
    if pointDepth == 0 {pointEnd=index;break}
}
let point = String(attachment[pointStart...pointEnd])
let limits = attachment.split(separator:"\n").map{$0.trimmingCharacters(in:.whitespaces)}.filter{
    $0.hasPrefix("static let holdableLongestEdgeMeters") || $0.hasPrefix("static var holdableLongestEdgeText")
}.joined(separator:"\n")
let bootstrap = try String(contentsOf:root.appendingPathComponent("apps/macos/Sources/GMGNRadio/App/LivingWorldBootstrap.swift"),encoding:.utf8)
let program = """
import Foundation
import WorldRuntime
enum ResidentPropAttachmentEligibility { \(limits) }
\(point)
\(declaration("struct MarbleLivingCabinCollisionWorld:",source:bootstrap))
final class MemoryOnly: WorldStatePersisting,@unchecked Sendable {
 var saved:WorldState
 init(_ state:WorldState){saved=state}
 func load() throws -> WorldState? {saved}
 func save(_ state:WorldState) throws {saved=state}
}
enum ProductionEntrance {
\(declaration("private static func supportLayer(at position: WorldVector3,"))
\(declaration("private static func footprint(at position: WorldVector3,"))
}
@main struct Checks {
 @MainActor static func main() throws {
    let endpoint = URL(fileURLWithPath: "/Users/ghostcorn/Library/Application Support/gmgn radio/TaskService/taskd.endpoint.json")
    let e = try JSONSerialization.jsonObject(with: Data(contentsOf:endpoint)) as! [String:Any]
    var request = URLRequest(url:URL(string:"http://" + (e["address"] as! String) + "/rpc")!)
    request.httpMethod = "POST"; request.setValue("Bearer " + (e["token"] as! String),forHTTPHeaderField:"Authorization")
    request.setValue("application/json",forHTTPHeaderField:"Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject:["id":"readonly-return-support","method":"world_snapshot","params":["worldID":"84503420-3010-4944-8fde-2f383cd08ebe","includeState":true]])
    let semaphore = DispatchSemaphore(value:0)
    var response:Data?; var failure:Error?
    URLSession.shared.dataTask(with:request) { data,_,error in response=data; failure=error; semaphore.signal() }.resume()
    guard semaphore.wait(timeout:.now()+10) == .success else { fatalError("Readonly snapshot timeout") }
    if let failure { throw failure }
    let envelope = try JSONSerialization.jsonObject(with:response!) as! [String:Any]
    let record = (envelope["result"] as! [String:Any])["record"] as! [String:Any]
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
    let state = try decoder.decode(WorldState.self,from:JSONSerialization.data(withJSONObject:record["state"]!))
    let package = URL(fileURLWithPath:"apps/macos/Resources/Worlds/marble-living-cabin")
    let config = try JSONSerialization.jsonObject(with:Data(contentsOf:package.appendingPathComponent("marble.json"))) as! [String:Any]
    let framing = config["framing"] as! [String:Any], origin = framing["origin"] as! [NSNumber]
    let triangles = try GLBColliderDecoder().decode(data:Data(contentsOf:package.appendingPathComponent("collider.glb")),transform:WorldMeshTransform(axisConversion:.flipYAndZ,origin:SIMD3(origin[0].floatValue,origin[1].floatValue,origin[2].floatValue),uniformScale:(framing["scale"] as! NSNumber).floatValue))
    let collision = TriangleMeshCollisionWorld(triangles:triangles)
    var minX=Float.infinity,maxX = -Float.infinity,minZ=Float.infinity,maxZ = -Float.infinity
    for triangle in triangles {
        for vertex in [triangle.first,triangle.second,triangle.third] {
            minX=min(minX,vertex.x);maxX=max(maxX,vertex.x)
            minZ=min(minZ,vertex.z);maxZ=max(maxZ,vertex.z)
        }
    }
    let grid = PropSupportGridBuilder.build(collision:collision,bounds:WorldPlanarBounds(minimumX:minX,maximumX:maxX,minimumZ:minZ,maximumZ:maxZ),seed:state.agentTransform.position)
    guard let held = state.heldProp else { fatalError("Readonly fixture no longer held") }
    var restored = state; restored.objectStates[held.objectID] = held.returnState; restored.heldProp = nil
    let obstacles = WorldLayoutObstacles.resolve(restored).obstacles
    for id in restored.objectStates.keys.sorted() {
        let item = restored.objectStates[id]!
        guard item.isEnabled,let prop=item.generatedProp else {continue}
        let q=item.transform.rotation, yaw=atan2(2*q.w*q.y,1-2*q.y*q.y)
        let size=prop.effectiveSize
        let footprint=ProductionEntrance.footprint(at:item.transform.position,size:SIMD2(size.x,size.z),yaw:yaw,spacing:grid.spacing)
        guard let anchor=ProductionEntrance.supportLayer(at:item.transform.position,footprint:footprint,grid:grid) else {print("SUPPORT_REJECT " + id);continue}
        let actual=footprint.center(anchoredAt:anchor.column,spacing:grid.spacing)
        precondition(abs(actual.x-item.transform.position.x)<0.00001 && abs(actual.y-item.transform.position.z)<0.00001)
        let reason=PropPlacementEvaluator.evaluate(footprint:footprint,height:size.y,at:anchor,grid:grid,collision:collision,blockingVolumes:[],placedObstacles:obstacles.filter{$0.id != id})
        print("ACTUAL_POSE " + id + " reason=" + String(describing:reason))
        if id == held.objectID {precondition(reason == nil,"Sword's real return pose must remain fully supported and collision-free")}
    }
    print("PASS exact formal held-return footprint evaluated without moving any formal object")
    let manifest = try decoder.decode(WorldManifest.self,from:Data(contentsOf:package.appendingPathComponent("world.json")))
    var baseline=state; baseline.activeActivity=nil
    let environment=MarbleLivingCabinCollisionWorld(environment:collision,props:CollisionVolumeWorld(volumes:manifest.collisionVolumes))
    let heights=manifest.waypoints.filter(\\.enabled).map(\\.position.y)
    let map=WorldPlacementRouteMap(grid:grid,lowerHeight:heights.min()!-0.2,upperHeight:heights.max()!+0.2)
    var anchors:[String:WorldVector3]=[:]
    for activity in manifest.activities {
        if let id=activity.entryWaypointID,let waypoint=manifest.waypoints.first(where:{$0.id==id && $0.enabled}) {anchors[id]=waypoint.position}
    }
    let support=ResidentPropPlacementSupport(grid:grid,collision:collision,
        routeConstraint:.init(map:map,anchorIDs:anchors.keys.sorted(),anchorPositions:anchors))
    func service(_ input:WorldState) throws -> ResidentPropPlacementService {
        let context=try WorldAgentContext(manifest:manifest,persistence:MemoryOnly(input),initialCollisionWorld:environment)
        return ResidentPropPlacementService(context:context,support:{support},currentAvatarAssetID:{held.avatarAssetID})
    }
    let returning=try service(baseline)
    let original=returning.context.state
    _ = try returning.commit(returning.returnHeldCommand(objectID:held.objectID),
        expectedLayoutRevision:original.layoutRevision,requestID:"isolated-original-return")
    precondition(returning.context.state.heldProp == nil)
    precondition(returning.context.state.objectStates[held.objectID] == held.returnState)
    for id in original.objectStates.keys where id != held.objectID {
        precondition(returning.context.state.objectStates[id] == original.objectStates[id])
    }
    print("PASS complete production service return on current authority snapshot; old unrelated sofa unchanged")
    let dropping=try service(baseline)
    let command=try dropping.dropHeldCommand(objectID:held.objectID)
    _ = try dropping.commit(command,expectedLayoutRevision:dropping.context.state.layoutRevision,requestID:"isolated-nearby-drop")
    precondition(dropping.context.state.heldProp == nil && dropping.context.state.objectStates[held.objectID]!.isEnabled)
    let dropped=dropping.context.state.objectStates[held.objectID]!.transform.position
    precondition(hypot(dropped.x-baseline.agentTransform.position.x,dropped.z-baseline.agentTransform.position.z)<=WorldPropActivityTemplate.interactionReach)
    print("PASS complete production nearby drop on current authority snapshot at \\(dropped)")
    var floating=baseline
    let bad=WorldHeldProp(objectID:held.objectID,avatarAssetID:held.avatarAssetID,hand:held.hand,returnState:{
        var item=held.returnState; let t=item.transform
        item.transform = .init(position:.init(x:t.position.x,y:t.position.y+0.1,z:t.position.z),rotation:t.rotation,scale:t.scale)
        return item
    }())
    floating.heldProp=bad
    let rejecting=try service(floating)
    let before=rejecting.context.state
    do {
        _ = try rejecting.commit(rejecting.returnHeldCommand(objectID:held.objectID),expectedLayoutRevision:before.layoutRevision,requestID:"isolated-floating-return")
        fatalError("Floating sword returned without real support")
    } catch ResidentPropPlacementError.unknownSurface {}
    precondition(rejecting.context.state == before)
    print("PASS floating sword return rejected atomically; no formal action issued")
 }
}
"""
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-real-return-\(UUID())")
try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:temporary)}
let source=temporary.appendingPathComponent("Checks.swift"), executable=temporary.appendingPathComponent("checks")
try program.write(to:source,atomically:true,encoding:.utf8)
let flags=Process(),pipe=Pipe();flags.executableURL=URL(fileURLWithPath:"/bin/sh");flags.arguments=[root.appendingPathComponent("tools/world-runtime-harness-flags.sh").path];flags.standardOutput=pipe
try flags.run();flags.waitUntilExit();precondition(flags.terminationStatus==0)
let arguments=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).split(separator:"\n").map(String.init)
let compiler=Process();compiler.executableURL=URL(fileURLWithPath:"/usr/bin/swiftc");compiler.arguments=["-j1","-parse-as-library",source.path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/WorldAgentContext.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentPropPlacementService.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/RetryBackoff.swift").path,"-o",executable.path]+arguments
try compiler.run();compiler.waitUntilExit();guard compiler.terminationStatus==0 else {exit(compiler.terminationStatus)}
let check=Process();check.executableURL=executable;try check.run();check.waitUntilExit();exit(check.terminationStatus)
