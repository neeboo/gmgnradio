import Foundation
let source=try String(contentsOfFile:"apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MarbleSpatialView.swift",encoding:.utf8)
let store=try String(contentsOfFile:"apps/macos/Sources/GMGNRadio/VisualEngine/SpatialStageStore.swift",encoding:.utf8)
let controller=try String(contentsOfFile:"apps/macos/Sources/GMGNRadio/VisualEngine/StageRenderSurfaceController.swift",encoding:.utf8)
func check(_ value:Bool,_ message:String) { if !value {print("FAIL:",message);exit(1)} }
guard let start=source.range(of:"enum ResidentPropSurfaceEligibility {") else {print("FAIL: actual render surface has no activity gate");exit(1)}
var depth=0,end=start.upperBound
for index in source.indices[start.lowerBound...] {
 let c=source[index];if c=="{" {depth+=1};if c=="}" {depth-=1;if depth==0 {end=source.index(after:index);break}}
}
let helper=String(source[start.lowerBound..<end])
func extracted(_ marker:String)->String {
 guard let range=source.range(of:marker) else {print("FAIL: missing lifecycle hook",marker);exit(1)}
 var level=0
 for index in source.indices[range.lowerBound...] {
  if source[index]=="{" {level+=1}
  if source[index]=="}" {level-=1;if level==0 {return String(source[range.lowerBound...index])}}
 }
 print("FAIL: incomplete lifecycle hook");exit(1)
}
check(controller.contains("surfaceView.setResidentPropRenderingActive(nextMode != .stopped)"),"actual manual render loop forwards active/stopped lifecycle")
check(source.contains("override var isHidden: Bool"),"hiding actual view releases owner immediately")
check(source.contains("spatialRenderer?.suspendResidentPropRendering()"),"actual surface lifecycle calls renderer release")
check(source.contains("isVisible: spatialStage.isWorldVisible && ResidentPropSurfaceEligibility.isActive(view)"),"draw lease uses actual MTKView activity")
check(source.contains("weak view"),"hook holds surface weakly")
check(source.components(separatedBy:"ResidentPropSurfaceEligibility.isActive(view)").count>=6,"prepare before/after await, cached lookup, status and active hook check surface")
check(store.components(separatedBy:"residentPropActiveHandler?() == true").count>=4,"prepare and both ray mappings check live surface")
let harness = """
import Foundation
import MetalKit
@MainActor final class StubRenderer {var suspensions=0;func suspendResidentPropRendering() {suspensions+=1}}
@MainActor final class RealLifecycleTypecheck: MetalKit.MTKView {
 var spatialRenderer:StubRenderer?
 var residentPropRenderingActive=false
 \(extracted("func setResidentPropRenderingActive(_ active: Bool)"))
 \(extracted("override var isHidden: Bool"))
}
@MainActor final class FakeWindow {var isVisible=true;var isMiniaturized=false}
@MainActor class MTKView {var window:FakeWindow?=FakeWindow();var isHiddenOrHasHiddenAncestor=false;var isPaused=true}
@MainActor final class MarbleSpatialView: MTKView {var residentPropRenderingActive=true}
@MainActor final class LifecycleState {
 var residentPropRenderingActive=true
 let spatialRenderer:StubRenderer?=StubRenderer()
 \(extracted("func setResidentPropRenderingActive(_ active: Bool)"))
}
@MainActor
\(helper)
func check(_ b:Bool,_ s:String) {if !b {print("FAIL:",s);exit(1)}}
@main struct Checks {
 @MainActor static func main() {
  let view=MarbleSpatialView()
  let lifecycle=LifecycleState()
  lifecycle.setResidentPropRenderingActive(false)
  check(!lifecycle.residentPropRenderingActive && lifecycle.spatialRenderer!.suspensions==1,"actual setter immediately releases owner when manual loop stops")
  lifecycle.setResidentPropRenderingActive(true)
  check(lifecycle.residentPropRenderingActive && lifecycle.spatialRenderer!.suspensions==1,"resuming loop does not suspend again")
  check(view.isPaused && ResidentPropSurfaceEligibility.isActive(view),"active manual renderer accepted while Metal display link paused")
  view.residentPropRenderingActive=false;check(!ResidentPropSurfaceEligibility.isActive(view),"stopped manual renderer rejected while shared world visible")
  view.residentPropRenderingActive=true;view.isHiddenOrHasHiddenAncestor=true;check(!ResidentPropSurfaceEligibility.isActive(view),"hidden parent rejected")
  view.isHiddenOrHasHiddenAncestor=false;view.window!.isVisible=false;check(!ResidentPropSurfaceEligibility.isActive(view),"hidden window rejected")
  view.window!.isVisible=true;view.window!.isMiniaturized=true;check(!ResidentPropSurfaceEligibility.isActive(view),"minimized window rejected")
  view.window=nil;check(!ResidentPropSurfaceEligibility.isActive(view),"detached surface rejected")
  print("PASS: production surface activity gate and lifecycle/hook/ray wiring")
 }
}
"""
let temp=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-prop-view-\(UUID())")
try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:temp)}
let file=temp.appendingPathComponent("main.swift"),exe=temp.appendingPathComponent("check")
try harness.write(to:file,atomically:true,encoding:.utf8)
func run(_ path:String,_ args:[String]) throws->Int32 {let p=Process();p.executableURL=URL(fileURLWithPath:path);p.arguments=args;try p.run();p.waitUntilExit();return p.terminationStatus}
let result=try run("/usr/bin/nice",["-n","15","/usr/bin/swiftc","-j1","-swift-version","6","-parse-as-library",file.path,"-o",exe.path])
guard result==0 else {exit(result)}
exit(try run(exe.path,[]))
