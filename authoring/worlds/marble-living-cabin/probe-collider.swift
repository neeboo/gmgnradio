// Read-only geometry probe using the application's actual decoder and collision code.
// Run from repository root: swift authoring/worlds/marble-living-cabin/probe-collider.swift
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let runtime = root.appendingPathComponent("apps/macos/Packages/WorldRuntime/Sources/WorldRuntime")
let sources = try ["WorldGeometry.swift", "WorldNavigation.swift", "GLBColliderDecoder.swift", "TriangleMeshCollisionWorld.swift"].map {
    try String(contentsOf: runtime.appendingPathComponent($0), encoding: .utf8)
}.joined(separator: "\n")
let probe = #"""
import Foundation
let data = try Data(contentsOf: URL(fileURLWithPath: "authoring/worlds/marble-living-cabin/assets/collider.glb"))
let raw = try GLBColliderDecoder().decode(data: data, transform: WorldMeshTransform(axisConversion: .flipYAndZ))
let vertices = raw.flatMap { [$0.first, $0.second, $0.third] }
func triple(_ value: SIMD3<Float>) -> [Float] { [value.x,value.y,value.z] }
let minPoint = SIMD3(vertices.map(\.x).min()!,vertices.map(\.y).min()!,vertices.map(\.z).min()!)
let maxPoint = SIMD3(vertices.map(\.x).max()!,vertices.map(\.y).max()!,vertices.map(\.z).max()!)
print("flipYAndZ bounds",triple(minPoint),triple(maxPoint),"triangles",raw.count)
var areas: [Int:Float] = [:]
for triangle in raw {
    let a=triangle.second-triangle.first, b=triangle.third-triangle.first
    let normal=SIMD3(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x)
    let length=sqrt(normal.x*normal.x+normal.y*normal.y+normal.z*normal.z)
    if length>0 && abs(normal.y)/length > 0.95 {
        let y=(triangle.first.y+triangle.second.y+triangle.third.y)/3
        areas[Int((y*20).rounded()), default:0] += length/2
    }
}
print("dominant horizontal surfaces (raw converted y, square units)",areas.sorted {$0.value > $1.value}.prefix(14).map {[Float($0.key)/20,$0.value]})
for originY:Float in [-1.7368507385253906 / 1.2125813961029053] {
    let triangles = try GLBColliderDecoder().decode(data:data,transform:WorldMeshTransform(axisConversion:.flipYAndZ,origin:SIMD3(0,originY,0),uniformScale:1.2125813961029053))
    let collision=TriangleMeshCollisionWorld(triangles:triangles)
    let capsule=WorldCapsule(radius:0.2,height:1.8)
    print("GRID origin y",originY,"letters .=clear ground <=0.3m #=collision _=missing")
    for z in stride(from:Float(-5),through:5,by:0.5) {
        var line=""
        for x in stride(from:Float(-5),through:5,by:0.5) {
            let p=SIMD3<Float>(x,0.3,z)
            if let y=collision.groundHeight(at:p), y > -0.4 {
                line += collision.canOccupy(capsule,at:SIMD3(x,y,z)) ? "." : "#"
            } else { line += "_" }
        }
        print(String(format:"z=%5.1f ",z)+line)
    }
    for p in [SIMD3<Float>(0,0.3,0),SIMD3<Float>(1,0.3,0),SIMD3<Float>(-1,0.3,0),SIMD3<Float>(0,0.3,1),SIMD3<Float>(0,0.3,-1)] {
        print("sample",triple(p),"ground",collision.groundHeight(at:p) as Any)
    }
    let proposed:[(String,Float,Float)] = [("spawn",-0.5,-2.5),("walk",-0.4,-1.8),("music",0.3,-3.0),("jukebox",1,-3),("camera-floor",-1,1.5)]
    var grounded:[SIMD3<Float>] = []
    for (name,x,z) in proposed {
        let y=collision.groundHeight(at:SIMD3(x,0.4,z)) ?? -999
        let p=SIMD3(x,y,z)
        grounded.append(p)
        print("PROPOSED",name,triple(p),"occupy",collision.canOccupy(capsule,at:p))
    }
    for (a,b) in [(0,1),(1,2),(0,2)] {
        print("ROUTE",proposed[a].0,proposed[b].0,collision.canTraverse(capsule,from:grounded[a],to:grounded[b],maximumStepHeight:0.25))
    }
    let camera=SIMD3<Float>(-1,2.15,1.5)
    print("CAMERA point capsule",collision.canOccupy(WorldCapsule(radius:0.05,height:0.1),at:camera-SIMD3(0,0.05,0)))
    print("CAMERA above +0.2m",collision.canOccupy(WorldCapsule(radius:0.05,height:0.1),at:camera+SIMD3(0,0.15,0)))
}
"""#
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-collider-probe-\(UUID())")
try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:temp) }
let script=temp.appendingPathComponent("main.swift")
try (sources+"\n"+probe).write(to:script,atomically:true,encoding:.utf8)
let process=Process()
process.executableURL=URL(fileURLWithPath:"/usr/bin/swift")
process.arguments=[script.path]
try process.run(); process.waitUntilExit(); exit(process.terminationStatus)
