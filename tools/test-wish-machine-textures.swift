// Metadata-only tests: never allocate the deliberately oversized image pixels.
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
let renderer=try String(contentsOfFile:"apps/macos/Sources/GMGNRadio/Presence/WishMachineOutputRenderer.swift",encoding:.utf8)
guard let start=renderer.range(of:"enum WishMachineTexturePolicy {")?.lowerBound else {print("FAIL: malformed/oversized GLB textures reach parallel decoder");exit(1)}
let policy=String(renderer[start...])
let harness = #"""
import Foundation
import GLTFCore
import ImageIO
\#(policy)
func check(_ value:Bool,_ message:String) {if !value {print("FAIL:",message);exit(1)}}
@main struct Tests {
    static func main() throws {
        let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "tmp/generated-props/espresso-machine-v1/model.glb"))
        let parsed=try GLTFParser().parse(data:data)
        let count=try WishMachineTexturePolicy.validate(document:parsed.document,binaryData:parsed.binaryData)
        check(count == 3,"actual coffee has three referenced textures")
        try WishMachineTexturePolicy.validateLoadedTextureCount(3,required:count)
        do {try WishMachineTexturePolicy.validateLoadedTextureCount(2,required:count);check(false,"swallowed texture decode failure must reject default-white output")} catch WishMachineOutputError.invalidTexture {}
        let image=parsed.document.images![0],view=parsed.document.bufferViews![image.bufferView!],offset=view.byteOffset ?? 0
        var broken=parsed.binaryData!
        broken.replaceSubrange(offset..<(offset+view.byteLength),with:Data(repeating:0,count:view.byteLength))
        do {_=try WishMachineTexturePolicy.validate(document:parsed.document,binaryData:broken);check(false,"damaged embedded PNG must fail")} catch WishMachineOutputError.invalidTexture {}
        func inflated(_ dimension:UInt32)->Data {
            var bytes=parsed.binaryData!
            for i in 0..<4 {
                bytes[offset+16+i]=UInt8((dimension >> (8*(3-i))) & 255)
                bytes[offset+20+i]=UInt8((dimension >> (8*(3-i))) & 255)
            }
            var crc:UInt32=0xffffffff
            for byte in bytes[(offset+12)..<(offset+29)] {
                crc ^= UInt32(byte)
                for _ in 0..<8 {crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0)}
            }
            crc ^= 0xffffffff
            for i in 0..<4 {bytes[offset+29+i]=UInt8((crc >> (8*(3-i))) & 255)}
            return bytes
        }
        do {_=try WishMachineTexturePolicy.validate(document:parsed.document,binaryData:inflated(8192));check(false,"8192 PNG header must fail before pixel allocation")} catch WishMachineOutputError.textureBudget {}
        var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(parsed.document)) as! [String:Any]
        let texture=(json["textures"] as! [[String:Any]])[0]
        json["textures"]=Array(repeating:texture,count:5)
        json["materials"]=[[
            "pbrMetallicRoughness":["baseColorTexture":["index":0],"metallicRoughnessTexture":["index":1]],
            "normalTexture":["index":2],"occlusionTexture":["index":3],"emissiveTexture":["index":4]
        ]]
        let duplicated=try JSONDecoder().decode(GLTFDocument.self,from:JSONSerialization.data(withJSONObject:json))
        do {_=try WishMachineTexturePolicy.validate(document:duplicated,binaryData:inflated(2048));check(false,"repeated image uploads count toward total pixel budget")} catch WishMachineOutputError.textureBudget {}
        var images=json["images"] as! [[String:Any]]
        images[0]["uri"]="https://example.invalid/private.png"
        json["images"]=images
        let external=try JSONDecoder().decode(GLTFDocument.self,from:JSONSerialization.data(withJSONObject:json))
        do {_=try WishMachineTexturePolicy.validate(document:external,binaryData:parsed.binaryData);check(false,"external texture never followed")} catch WishMachineOutputError.invalidTexture {}
        print("PASS: real coffee textures, missing decode rejects white fallback, bad PNG, 8192 image metadata, total pixel budget, external URI rejection")
    }
}
"""#
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
let products=root.appendingPathComponent("apps/macos/Build.noindex/Build/Products/Debug")
let directory=root.appendingPathComponent("apps/macos/Build.noindex/Build/Intermediates.noindex/VRMMetalKit.build/Debug/GLTFCore.build/Objects-normal/arm64")
let objects=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter {$0.pathExtension == "o"}.map(\.path)
let temp=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-texture-test-\(UUID())")
try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:temp)}
let test=temp.appendingPathComponent("main.swift"),exe=temp.appendingPathComponent("check")
try harness.write(to:test,atomically:true,encoding:.utf8)
func run(_ path:String,_ args:[String]) throws->Int32 {let p=Process();p.executableURL=URL(fileURLWithPath:path);p.arguments=args;try p.run();p.waitUntilExit();return p.terminationStatus}
// `-I products` 只给 GLTFCore；WorldRuntime 的模块与目标文件走唯一那一处定义
// （worldRuntimeHarnessFlags，排在 products 前面所以优先命中，不会取到 xcodebuild 的旧 Debug 模块）。
// `PropSizeIntent` 是 **App 侧**的类型（`PropGenerationClient.swift` 拥有它，不是 WorldRuntime 的）：
// 描述符引用它，所以那份真源码必须一起编进来 —— 编同一份，不是补个同名 stub。
// （这条与 WorldRuntime 无关，是本 harness 自己漏挂的旧账：HEAD 上就已经缺它。）
let result=try run("/usr/bin/nice",["-n","15","/usr/bin/swiftc","-j1","-swift-version","6","-target","arm64-apple-macosx26.0","-parse-as-library"]+worldRuntimeHarnessFlags()+["-I",products.path,"apps/macos/Sources/GMGNRadio/Presence/PropGenerationClient.swift","apps/macos/Sources/GMGNRadio/Presence/WishMachineOutputDescriptor.swift",test.path]+objects+["-framework","Metal","-framework","MetalKit","-framework","ImageIO","-o",exe.path])
guard result == 0 else {exit(result)}
exit(try run(exe.path,Array(CommandLine.arguments.dropFirst())))
