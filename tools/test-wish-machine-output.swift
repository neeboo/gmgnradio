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
let source = "apps/macos/Sources/GMGNRadio/Presence/WishMachineOutputDescriptor.swift"
// `PropSizeIntent` 是 **App 侧**的类型（`PropGenerationClient.swift` 拥有它，不是 WorldRuntime
// 的）。描述符引用它，所以那份真源码必须一起编进来 —— 编同一份，不是在这里补个同名 stub。
// （这条与 WorldRuntime 无关，是本 harness 自己漏挂的旧账：HEAD 上就已经缺它。）
let sizeIntentSource = "apps/macos/Sources/GMGNRadio/Presence/PropGenerationClient.swift"
guard FileManager.default.fileExists(atPath:source) else { print("FAIL: no metre-scale, world-scoped wish output contract");exit(1) }
guard FileManager.default.fileExists(atPath:sizeIntentSource) else { print("FAIL: PropSizeIntent owner source is missing");exit(1) }
let harness = #"""
import Foundation
import simd
func check(_ value: Bool, _ message: String) { if !value { print("FAIL:",message);exit(1) } }
@main struct Tests {
    static func main() throws {
        let fixture = URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "tmp/generated-props/espresso-machine-v1/model.glb")
        let data = try Data(contentsOf: fixture)
        func u32(_ offset:Int)->Int { (0..<4).reduce(0) { $0 | Int(data[offset+$1]) << (8*$1) } }
        check(data.prefix(4) == Data("glTF".utf8), "actual coffee GLB fixture")
        let json = try JSONSerialization.jsonObject(with:data.subdata(in:20..<(20+u32(12)))) as! [String:Any]
        let accessors = json["accessors"] as! [[String:Any]]
        let primitive = ((json["meshes"] as! [[String:Any]])[0]["primitives"] as! [[String:Any]])[0]
        let position = (primitive["attributes"] as! [String:Int])["POSITION"]!
        func vector(_ key:String)->SIMD3<Float> { let v=(accessors[position][key] as! [NSNumber]).map(\.floatValue);return SIMD3(v[0],v[1],v[2]) }
        for node in json["nodes"] as! [[String:Any]] {
            check(node["matrix"] == nil && node["translation"] == nil && node["scale"] == nil && node["rotation"] == nil,"fixture accessor bounds are world bounds")
        }
        let minimum=vector("min"), maximum=vector("max"), outlet=SIMD3<Float>(0.8,0.732,-2.6)
        let matrix=try WishMachineOutputPlacement.transform(minimum:minimum,maximum:maximum,targetHeight:0.42,outlet:outlet)
        let centre=(minimum+maximum)/2
        let bottom=matrix*SIMD4(centre.x,minimum.y,centre.z,1)
        let top=matrix*SIMD4(centre.x,maximum.y,centre.z,1)
        check(simd_length(SIMD3(bottom.x,bottom.y,bottom.z)-outlet)<0.00001,"actual coffee bottom floats at outlet")
        check(abs(top.y-bottom.y-0.42)<0.00001,"actual coffee normalizes to 42 cm")
        for h:Float in [0,-1,.nan,.infinity,11] {
            do { _=try WishMachineOutputPlacement.transform(minimum:minimum,maximum:maximum,targetHeight:h,outlet:outlet);check(false,"reject invalid height") } catch WishMachineOutputError.invalidDimensions {}
        }
        do { _=try WishMachineOutputPlacement.transform(minimum:minimum,maximum:minimum,targetHeight:0.4,outlet:outlet);check(false,"reject collapsed bounds") } catch WishMachineOutputError.invalidDimensions {}
        for z:Float in [0,0.1,0.5,0.9,1] {
            let clip=SIMD4<Float>(0,0,z*4,4)
            let forward=WishMachineOutputPlacement.projection(matrix_identity_float4x4,reversedDepth:false)*clip
            let reverse=WishMachineOutputPlacement.projection(matrix_identity_float4x4,reversedDepth:true)*clip
            check(abs(forward.z/forward.w-z)<0.00001,"forward Metal depth")
            check(abs(reverse.z/reverse.w-(1-z))<0.00001,"SceneKit reverse depth matches w-z prepass")
        }
        print("PASS: real coffee GLB 42 cm placement, suspended bottom, bad dimensions, forward/reversed clip depth")
    }
}
"""#
let temp=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-output-test-\(UUID())")
try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:temp)}
let test=temp.appendingPathComponent("main.swift"), executable=temp.appendingPathComponent("check")
try harness.write(to:test,atomically:true,encoding:.utf8)
func run(_ path:String,_ args:[String]) throws->Int32 {let p=Process();p.executableURL=URL(fileURLWithPath:path);p.arguments=args;try p.run();p.waitUntilExit();return p.terminationStatus}
let code=try run("/usr/bin/nice",["-n","15","/usr/bin/swiftc","-j1","-parse-as-library"]+worldRuntimeHarnessFlags()+[sizeIntentSource,source,test.path,"-o",executable.path])
guard code == 0 else {exit(code)}
exit(try run(executable.path,Array(CommandLine.arguments.dropFirst())))
