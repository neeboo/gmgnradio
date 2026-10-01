// Tiny offscreen GPU check only: no app host, window or user document access.
// Requires the app's Debug build to have compiled the pinned GLTFMetalKit product.
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
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let products = root.appendingPathComponent("apps/macos/Build/Build/Products/Debug")
guard FileManager.default.fileExists(atPath: products.appendingPathComponent("GLTFMetalKit.swiftmodule").path) else {
    print("FAIL: first compile the app with its pinned GLTFMetalKit product");exit(1)
}
let harness = #"""
import Foundation
import Metal
import simd
func check(_ value: Bool, _ message: String) { if !value { print("FAIL:",message);exit(1) } }
@main struct GPUCheck {
    @MainActor static func main() async throws {
        guard let device=MTLCreateSystemDefaultDevice(), let queue=device.makeCommandQueue() else { throw WishMachineOutputError.renderUnavailable }
        let colorDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:192,height:192,mipmapped:false)
        colorDescriptor.usage=[.renderTarget];colorDescriptor.storageMode = .shared
        let depthDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:192,height:192,mipmapped:false)
        depthDescriptor.usage=[.renderTarget];depthDescriptor.storageMode = .private
        let color=device.makeTexture(descriptor:colorDescriptor)!,depth=device.makeTexture(descriptor:depthDescriptor)!
        let renderer=WishMachineOutputRenderer(device:device,colorFormat:.rgba8Unorm,depthFormat:.depth32Float)
        var status=WishMachineOutputStatus.empty
        renderer.onStatusChanged={ status=$0 }
        let world=WishMachineScene.worldID
        let item=WishMachineOutputDescriptor(id:"coffee-test",worldID:world,modelURL:URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "tmp/generated-props/espresso-machine-v1/model.glb"),targetHeightMeters:0.42)
        renderer.update(item,worldID:world,isVisible:true)
        check(status == .loading(id:item.id),"descriptor assignment does not report ready")
        let eye=SIMD3<Float>(0.8,0.942,-1.1)
        let f:Float=1/tan(50*Float.pi/360),near:Float=0.05,far:Float=20
        var projection=simd_float4x4()
        projection.columns=(SIMD4(f,0,0,0),SIMD4(0,f,0,0),SIMD4(0,0,far/(near-far),-1),SIMD4(0,0,far*near/(near-far),0))
        var view=matrix_identity_float4x4;view.columns.3=SIMD4(-eye.x,-eye.y,-eye.z,1)
        func frame(reverse:Bool,blocked:Bool) async -> (Bool,Int) {
            let command=queue.makeCommandBuffer()!
            let pass=MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture=color;pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1)
            pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction = .clear;pass.depthAttachment.storeAction = .store
            pass.depthAttachment.clearDepth=blocked ? (reverse ? 1 : 0) : (reverse ? 0 : 1)
            command.makeRenderCommandEncoder(descriptor:pass)!.endEncoding()
            let drawn=renderer.render(commandBuffer:command,colorTexture:color,depthTexture:depth,viewProjection:projection*view,cameraPosition:eye,reversedDepth:reverse,preservesDepth:true)
            await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
                command.addCompletedHandler { _ in continuation.resume() };command.commit()
            }
            check(command.status == .completed,"offscreen command completes")
            var pixels=[UInt8](repeating:0,count:192*192*4)
            pixels.withUnsafeMutableBytes { color.getBytes($0.baseAddress!,bytesPerRow:192*4,from:MTLRegionMake2D(0,0,192,192),mipmapLevel:0) }
            let lit=stride(from:0,to:pixels.count,by:4).filter { pixels[$0]>3 || pixels[$0+1]>3 || pixels[$0+2]>3 }.count
            return (drawn,lit)
        }
        var visible=0
        for _ in 0..<500 {
            let result=await frame(reverse:false,blocked:false)
            if result.0 { visible=result.1;break }
            if case let .failed(_,message)=status { print("FAIL:",message);exit(1) }
            try await Task.sleep(for:.milliseconds(20))
        }
        check(visible>100,"actual coffee has visible textured pixels")
        await Task.yield()
        check(status == .ready(id:item.id),"ready follows successful real mesh GPU completion")
        let forwardBlocked=await frame(reverse:false,blocked:true)
        let reverseVisible=await frame(reverse:true,blocked:false)
        let reverseBlocked=await frame(reverse:true,blocked:true)
        check(forwardBlocked.1 == 0,"forward near depth fully occludes real coffee")
        check(reverseVisible.1>100,"reverse depth displays real coffee")
        check(reverseBlocked.1 == 0,"reverse near depth fully occludes real coffee")
        check(abs(visible-reverseVisible.1)<=3,"forward and SceneKit depth preserve identical silhouette")
        renderer.update(item,worldID:"different-world",isVisible:true)
        check(status == .empty,"world change clears output")
        let cleared=await frame(reverse:false,blocked:false)
        check(!cleared.0 && cleared.1 == 0,"world change leaves no stale output mesh")
        renderer.update(item,worldID:world,isVisible:true)
        renderer.update(nil,worldID:world,isVisible:false)
        try await Task.sleep(for:.milliseconds(100))
        check(status == .empty,"late cancelled load cannot restore cleared output")
        print("PASS: coffee offscreen GPU pixels",visible,"reverse",reverseVisible.1,"both blocked 0; ready callback, world reset, stale load discard")
    }
}
"""#
let intermediates=root.appendingPathComponent("apps/macos/Build/Build/Intermediates.noindex/VRMMetalKit.build/Debug")
var objects:[String]=[]
for product in ["GLTFMetalKit","GLTFCore"] {
    let path=intermediates.appendingPathComponent("\(product).build/Objects-normal/arm64")
    objects += try FileManager.default.contentsOfDirectory(at:path,includingPropertiesForKeys:nil).filter {$0.pathExtension == "o"}.map(\.path)
}
let temp=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-output-gpu-test-\(UUID())")
try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:temp)}
let bundle=products.appendingPathComponent("VRMMetalKit_GLTFMetalKit.bundle")
if FileManager.default.fileExists(atPath:bundle.path) {try FileManager.default.copyItem(at:bundle,to:temp.appendingPathComponent(bundle.lastPathComponent))}
let test=temp.appendingPathComponent("main.swift"),exe=temp.appendingPathComponent("check")
try harness.write(to:test,atomically:true,encoding:.utf8)
// `PropSizeIntent` 是 **App 侧**的类型（`PropGenerationClient.swift` 拥有它，不是 WorldRuntime 的）：
// 描述符引用它，所以那份真源码必须一起编进来 —— 编同一份，不是补个同名 stub。
// （这条与 WorldRuntime 无关，是本 harness 自己漏挂的旧账：HEAD 上就已经缺它。）
let sources=["PropGenerationClient.swift","WishMachineScene.swift","WishMachineOutputDescriptor.swift","WishMachineOutputRenderer.swift"].map {"apps/macos/Sources/GMGNRadio/Presence/"+$0}
func run(_ path:String,_ args:[String]) throws->Int32 {let p=Process();p.executableURL=URL(fileURLWithPath:path);p.arguments=args;try p.run();p.waitUntilExit();return p.terminationStatus}
// `-I products` 只给 GLTFCore / GLTFMetalKit；WorldRuntime 的模块与目标文件走唯一那一处定义
// （worldRuntimeHarnessFlags，排在 products 前面所以优先命中，不会取到 xcodebuild 的旧 Debug 模块）。
let result=try run("/usr/bin/nice",["-n","15","/usr/bin/swiftc","-j1","-swift-version","6","-target","arm64-apple-macosx26.0","-parse-as-library"]+worldRuntimeHarnessFlags()+["-I",products.path]+sources+[test.path]+objects+["-framework","Metal","-framework","MetalKit","-framework","SceneKit","-framework","AppKit","-o",exe.path])
guard result == 0 else {exit(result)}
exit(try run(exe.path,Array(CommandLine.arguments.dropFirst())))
