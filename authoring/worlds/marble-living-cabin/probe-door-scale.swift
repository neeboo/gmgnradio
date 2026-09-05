// Read-only panorama landmark ray probe using the production GLB decoder.
// Run from repository root: swift authoring/worlds/marble-living-cabin/probe-door-scale.swift
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let runtime = root.appendingPathComponent("apps/macos/Packages/WorldRuntime/Sources/WorldRuntime")
let sources = try ["WorldGeometry.swift", "WorldNavigation.swift", "GLBColliderDecoder.swift", "TriangleMeshCollisionWorld.swift"].map {
    try String(contentsOf: runtime.appendingPathComponent($0), encoding: .utf8)
}.joined(separator: "\n")
let probe = #"""
import Foundation
let data = try Data(contentsOf: URL(fileURLWithPath: "authoring/worlds/marble-living-cabin/assets/collider.glb"))
let triangles = try GLBColliderDecoder().decode(data: data, transform: WorldMeshTransform(axisConversion: .flipYAndZ))
// Preserve the provider's ORIGINAL baseline, so later layout edits do not
// silently change this measurement. This equals the pre-correction layout.
let metricScale: Float = 1.2125813961029053
func cross3(_ a: SIMD3<Float>,_ b: SIMD3<Float>) -> SIMD3<Float> { SIMD3(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x) }
func dot3(_ a: SIMD3<Float>,_ b: SIMD3<Float>) -> Float { a.x*b.x+a.y*b.y+a.z*b.z }
func hit(_ direction: SIMD3<Float>) -> SIMD3<Float>? {
    var nearest = Float.infinity
    for triangle in triangles {
        let a=triangle.second-triangle.first,b=triangle.third-triangle.first
        let p=cross3(direction,b), determinant=dot3(a,p)
        if abs(determinant)<0.000001 {continue}
        let t = -triangle.first, inverse=1/determinant
        let u=dot3(t,p)*inverse
        if u<0 || u>1 {continue}
        let q=cross3(t,a),v=dot3(direction,q)*inverse
        if v<0 || u+v>1 {continue}
        let distance=dot3(b,q)*inverse
        if distance>0.0001 {nearest=min(nearest,distance)}
    }
    return nearest.isFinite ? direction*nearest : nil
}
func ray(u: Float,v: Float,offset: Float,sign: Float) -> SIMD3<Float> {
    let theta=2*Float.pi*(u+offset),phi=Float.pi*(v-0.5)
    return SIMD3(sign*sin(theta)*cos(phi),-sin(phi),cos(theta)*cos(phi))
}
func triple(_ p: SIMD3<Float>) -> String {String(format:"[%.4f,%.4f,%.4f]",p.x,p.y,p.z)}
// Coordinates are fractions of the 4608x2304 RGB panorama. Door seam endpoints
// use the centre of each visible door, excluding the projecting lit threshold.
let doors:[(String,Float,Float,Float)] = [("left",0.044,0.537,0.605),("right",0.559,0.532,0.578)]
for sign:Float in [-1,1] {
    for offset:Float in [0,0.25,0.5,0.75] {
        print("ORIENTATION xsign",sign,"turnOffset",offset)
        for (name,u,top,bottom) in doors {
            guard let a=hit(ray(u:u,v:top,offset:offset,sign:sign)),let b=hit(ray(u:u,v:bottom,offset:offset,sign:sign)) else { print("MISSING",name);continue }
            let separation=sqrt(pow(a.x-b.x,2)+pow(a.z-b.z,2))
            print(name,"top",triple(a),"bottom",triple(b),"height_m",(a.y-b.y)*metricScale,"horizontal_drift_raw",separation)
        }
    }
}
// The accepted orientation is supported by both door thresholds hitting the
// raw ground band at y=-1.35...-1.36 and close top/bottom horizontal positions.
// No pano extrinsics were exported, so this remains an empirical alignment.
print("SENSITIVITY: accepted orientation xsign=-1 offset=0; +/-0.002 UV (9px horizontal, 5px vertical)")
for (name,u,top,bottom) in doors {
    var heights:[Float]=[]
    var drifts:[Float]=[]
    for du:Float in [-0.002,0,0.002] {
        for dt:Float in [-0.002,0,0.002] {
            for db:Float in [-0.002,0,0.002] {
                guard let a=hit(ray(u:u+du,v:top+dt,offset:0,sign:-1)),let b=hit(ray(u:u+du,v:bottom+db,offset:0,sign:-1)) else {continue}
                heights.append((a.y-b.y)*metricScale)
                drifts.append(sqrt(pow(a.x-b.x,2)+pow(a.z-b.z,2))*metricScale)
            }
        }
    }
    heights.sort()
    print(name,"sample_count",heights.count,"height_m_min_median_max",heights.first!,heights[heights.count/2],heights.last!,"max_horizontal_drift_m",drifts.max()!)
    print(name,"at_2x_scale_min_median_max",2*heights.first!,2*heights[heights.count/2],2*heights.last!)
}
"""#
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = ["-"]
let input = Pipe()
process.standardInput = input
try process.run()
try input.fileHandleForWriting.write(contentsOf: Data((sources + "\n" + probe).utf8))
try input.fileHandleForWriting.close()
process.waitUntilExit()
exit(process.terminationStatus)
