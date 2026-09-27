// Metadata-only tests: never allocate the deliberately oversized image pixels.
import Foundation
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
let products=root.appendingPathComponent("apps/macos/Build/Build/Products/Debug")
let directory=root.appendingPathComponent("apps/macos/Build/Build/Intermediates.noindex/VRMMetalKit.build/Debug/GLTFCore.build/Objects-normal/arm64")
let objects=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter {$0.pathExtension == "o"}.map(\.path)
let temp=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-texture-test-\(UUID())")
try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:temp)}
let test=temp.appendingPathComponent("main.swift"),exe=temp.appendingPathComponent("check")
try harness.write(to:test,atomically:true,encoding:.utf8)
func run(_ path:String,_ args:[String]) throws->Int32 {let p=Process();p.executableURL=URL(fileURLWithPath:path);p.arguments=args;try p.run();p.waitUntilExit();return p.terminationStatus}
let result=try run("/usr/bin/nice",["-n","15","/usr/bin/swiftc","-j1","-swift-version","6","-target","arm64-apple-macosx26.0","-parse-as-library","-I",products.path,"apps/macos/Sources/GMGNRadio/Presence/WishMachineOutputDescriptor.swift",test.path]+objects+["-framework","Metal","-framework","MetalKit","-framework","ImageIO","-o",exe.path])
guard result == 0 else {exit(result)}
exit(try run(exe.path,Array(CommandLine.arguments.dropFirst())))
