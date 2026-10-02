// Offscreen only: actual generated coffee, no window or app host.
import Foundation
// WorldRuntime 的模块搜索路径与目标文件**只有一处定义**：tools/world-runtime-harness-flags.sh。
// harness 一律调用它，绝不自己拼 `.build/...`（27 份各自拼写正是 SwiftPM 模块与 xcodebuild
// `Products/Debug` 旧模块两份并存的根因，后者报 `WorldQuaternion` 没有 `identity`）。
func worldRuntimeHarnessFlags() -> [String] {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [FileManager.default.currentDirectoryPath + "/tools/world-runtime-harness-flags.sh"]
    process.standardOutput = pipe
    try? process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
}
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
let products=root.appendingPathComponent("apps/macos/Build.noindex/Build/Products/Debug")
let harness = #"""
import Foundation
import Metal
import simd
struct ResidentHeldPropDescriptor {
 let objectID:String;let worldID:String;let assetID:String;let modelURL:URL;let targetHeightMeters:Float
 var assetKey:String { assetID+"|"+modelURL.standardizedFileURL.path }
}
enum PropAttachmentError:Error { case assetNotPrepared }
enum PropAttachmentMatrix {
 static func transform(minimum:SIMD3<Float>,maximum:SIMD3<Float>,descriptor:ResidentHeldPropDescriptor,
                       handPose:simd_float4x4)throws->simd_float4x4 { handPose }
}
func check(_ value: Bool, _ message: String) { if !value { print("FAIL:",message);exit(1) } }
@main struct Checks {
 @MainActor static func main() async throws {
  let device=MTLCreateSystemDefaultDevice()!,queue=device.makeCommandQueue()!
  let cd=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:192,height:192,mipmapped:false)
  cd.usage=[.renderTarget];cd.storageMode = .shared
  let dd=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:192,height:192,mipmapped:false)
  dd.usage=[.renderTarget];dd.storageMode = .private
  let color=device.makeTexture(descriptor:cd)!,depth=device.makeTexture(descriptor:dd)!
  let renderer=ResidentPropRenderer(device:device,colorFormat:.rgba8Unorm,depthFormat:.depth32Float)
  var statuses:[String:WishMachineOutputStatus]=[:]
  renderer.onStatusChanged={ statuses[$0]=$1 }
  let url=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "tmp/wish-machine-service-proof-20260906/core/10B3433A-6B1E-43AD-887E-A9F25FC78439.glb")
  let item=ResidentPropRenderDescriptor(objectID:"coffee",worldID:"test",assetID:"coffee-hash",modelURL:url,targetHeightMeters:0.42,position:SIMD3(0,0,0),yaw:0)
  renderer.update([],preview:nil,worldID:"test",isVisible:true)
  let prepared=try await renderer.prepare(item)
  check(renderer.isPrepared(assetID:item.assetID,modelURL:url),"prepare cache lookup uses verified identity")
  check(prepared.sourceHeight>0 && abs(prepared.size.y-0.42)<0.00001,"prepare returns actual metre-scaled bounds")
  print("Actual prepared coffee size",prepared.size,"source height",prepared.sourceHeight)
  check(simd_length(prepared.size-SIMD3<Float>(0.35069498,0.42,0.56627256))<0.00001,"real loader bounds match collision fixture coffee size")
  check(statuses.isEmpty,"prepare alone does not claim world display or ready")
  let eye=SIMD3<Float>(0,0.21,1.5),f:Float=1/tan(50*Float.pi/360),near:Float=0.05,far:Float=20
  var projection=simd_float4x4()
  projection.columns=(SIMD4(f,0,0,0),SIMD4(0,f,0,0),SIMD4(0,0,far/(near-far),-1),SIMD4(0,0,far*near/(near-far),0))
  var view=matrix_identity_float4x4;view.columns.3=SIMD4(-eye.x,-eye.y,-eye.z,1)
  func frame(reverse:Bool=false,blocked:Bool=false) async -> Int {
   let command=queue.makeCommandBuffer()!,pass=MTLRenderPassDescriptor()
   pass.colorAttachments[0].texture=color;pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
   pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1)
   pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction = .clear;pass.depthAttachment.storeAction = .store
   pass.depthAttachment.clearDepth=blocked ? (reverse ? 1:0):(reverse ? 0:1)
   command.makeRenderCommandEncoder(descriptor:pass)!.endEncoding()
   _=renderer.render(commandBuffer:command,colorTexture:color,depthTexture:depth,viewProjection:projection*view,cameraPosition:eye,reversedDepth:reverse,preservesDepth:true)
   await withCheckedContinuation { (c:CheckedContinuation<Void,Never>) in command.addCompletedHandler { _ in c.resume() };command.commit() }
   check(command.status == .completed,"real GPU command completes")
   await Task.yield()
   var pixels=[UInt8](repeating:0,count:192*192*4)
   pixels.withUnsafeMutableBytes { color.getBytes($0.baseAddress!,bytesPerRow:192*4,from:MTLRegionMake2D(0,0,192,192),mipmapLevel:0) }
   return stride(from:0,to:pixels.count,by:4).filter { pixels[$0]>3 || pixels[$0+1]>3 || pixels[$0+2]>3 }.count
  }
  check(await frame()==0,"prepared asset is not displayed until explicit placement")
  renderer.update([item],preview:nil,worldID:"test",isVisible:true)
  check(statuses[item.objectID] == .loading(id:item.objectID),"placement not ready before GPU")
  let visible=await frame()
  check(visible>100,"actual new coffee visible")
  check(statuses[item.objectID] == .ready(id:item.objectID),"ready only after actual GPU frame")
  check(await frame(blocked:true)==0,"forward depth occludes coffee")
  let reverse=await frame(reverse:true)
  check(abs(reverse-visible)<=3,"reverse depth matches actual silhouette")
  check(await frame(reverse:true,blocked:true)==0,"reverse depth occludes coffee")
  var preview=item;preview.position.x=5;preview.yaw=1.4
  renderer.update([item],preview:preview,worldID:"test",isVisible:true)
  check(await frame()==0,"preview replaces formal mesh without ghost")
  renderer.update([item],preview:nil,worldID:"test",isVisible:true)
  check(await frame()==visible,"cancel restores exact original image")
  for index in 0..<30 { preview.position.x=Float(index)/100;renderer.update([item],preview:preview,worldID:"test",isVisible:true);_=await frame() }
  check(renderer.assetLoadCount==1,"preview only changes matrices, no reload/upload")
  let second=ResidentPropRenderDescriptor(objectID:"second",worldID:"test",assetID:item.assetID,modelURL:url,targetHeightMeters:0.2,position:SIMD3(0.4,0,0),yaw:0)
  _=try await renderer.prepare(second)
  renderer.update([item,second],preview:nil,worldID:"test",isVisible:true)
  check(await frame()>visible && renderer.assetLoadCount==1,"two differently scaled objects share original asset")
  let invalid=ResidentPropRenderDescriptor(objectID:"invalid",worldID:"test",assetID:"missing",modelURL:URL(fileURLWithPath:"/tmp/no-resident-prop-fixture.glb"),targetHeightMeters:0.3,position:.zero,yaw:0)
  do { _=try await renderer.prepare(invalid);check(false,"bad file blocks preparation") } catch {}
  renderer.update([item],preview:nil,worldID:"other",isVisible:true)
  check(!renderer.isPrepared(assetID:item.assetID,modelURL:url),"world switch invalidates preparation lookup")
  check(await frame()==0,"world switch clears all visible assets")
  do { _=try await renderer.prepare(item);check(false,"cross-world prepare rejected") } catch is CancellationError {}
  renderer.update([item],preview:nil,worldID:"test",isVisible:true)
  renderer.update([],preview:nil,worldID:nil,isVisible:false)
  try await Task.sleep(for:.milliseconds(100))
  check(await frame()==0,"late load cannot restore hidden-world objects")
  print("PASS: real coffee",visible,"pixels; prepare/ready separation, shared resources, move/yaw/cancel, both depth modes, world cleanup")
 }
}
"""#
let temp=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-prop-gpu-\(UUID())")
try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:temp)}
let bundle=products.appendingPathComponent("VRMMetalKit_GLTFMetalKit.bundle")
try FileManager.default.copyItem(at:bundle,to:temp.appendingPathComponent(bundle.lastPathComponent))
let source=temp.appendingPathComponent("main.swift"),exe=temp.appendingPathComponent("check")
try harness.write(to:source,atomically:true,encoding:.utf8)
var objects:[String]=[]
let intermediates=root.appendingPathComponent("apps/macos/Build.noindex/Build/Intermediates.noindex/VRMMetalKit.build/Debug")
for name in ["GLTFMetalKit","GLTFCore"] {
 objects += try FileManager.default.contentsOfDirectory(at:intermediates.appendingPathComponent("\(name).build/Objects-normal/arm64"),includingPropertiesForKeys:nil).filter {$0.pathExtension=="o"}.map(\.path)
}
// `PropSizeIntent` 是 **App 侧**的类型（`PropGenerationClient.swift` 拥有它，不是 WorldRuntime 的）：
// 描述符引用它，所以那份真源码必须一起编进来 —— 编同一份，不是补个同名 stub。
// （这条与 WorldRuntime 无关，是本 harness 自己漏挂的旧账：HEAD 上就已经缺它。）
let sources=["PropGenerationClient.swift","WishMachineScene.swift","WishMachineOutputDescriptor.swift","WishMachineOutputRenderer.swift","ResidentPropRenderer.swift"].map { "apps/macos/Sources/GMGNRadio/Presence/"+$0 }
func run(_ path:String,_ args:[String]) throws->Int32 {let p=Process();p.executableURL=URL(fileURLWithPath:path);p.arguments=args;try p.run();p.waitUntilExit();return p.terminationStatus}
// `-I products` 只给 GLTFCore / GLTFMetalKit；WorldRuntime 的模块与目标文件走唯一那一处定义
// （worldRuntimeHarnessFlags，排在 products 前面所以优先命中，不会取到 xcodebuild 的旧 Debug 模块）。
let result=try run("/usr/bin/nice",["-n","15","/usr/bin/swiftc","-j1","-swift-version","6","-target","arm64-apple-macosx26.0","-parse-as-library"]+worldRuntimeHarnessFlags()+["-I",products.path]+sources+[source.path]+objects+["-framework","Metal","-framework","MetalKit","-framework","SceneKit","-framework","AppKit","-o",exe.path])
guard result==0 else {exit(result)}
exit(try run(exe.path,Array(CommandLine.arguments.dropFirst())))
