// Offscreen SceneKit/Metal acceptance for the wish-machine body at the actual
// Marble living-cabin presentation camera. No app host or window is started.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let harness = #"""
import AppKit
import Foundation
import Metal
import SceneKit
import simd

func check(_ value: Bool, _ message: String) {
    if !value { print("FAIL:", message); exit(1) }
}

struct MarbleConfig: Decodable {
    struct Camera: Decodable {
        let position: [Float]
        let yaw: Float
        let pitch: Float
    }
    let camera: Camera
}

func translation(_ value: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(columns: (
        SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
        SIMD4(0, 0, 1, 0), SIMD4(value.x, value.y, value.z, 1)
    ))
}

func rotationX(_ angle: Float) -> simd_float4x4 {
    let c = cos(angle), s = sin(angle)
    return simd_float4x4(columns: (
        SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0),
        SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)
    ))
}

func rotationY(_ angle: Float) -> simd_float4x4 {
    let c = cos(angle), s = sin(angle)
    return simd_float4x4(columns: (
        SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0),
        SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1)
    ))
}

func perspective(fieldOfView: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fieldOfView * 0.5)
    let x = y / aspect
    return simd_float4x4(columns: (
        SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0),
        SIMD4(0, 0, far / (near - far), -1),
        SIMD4(0, 0, far * near / (near - far), 0)
    ))
}

@main struct Check {
    @MainActor static func main() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { fatalError("Metal unavailable") }

        let configURL = URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin/marble.json")
        let config = try JSONDecoder().decode(MarbleConfig.self, from: Data(contentsOf: configURL))
        let width = 512, height = 320
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        colorDescriptor.usage = [.renderTarget]
        colorDescriptor.storageMode = .shared
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false
        )
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private
        let color = device.makeTexture(descriptor: colorDescriptor)!
        let depth = device.makeTexture(descriptor: depthDescriptor)!

        let scene = SCNScene()
        scene.background.contents = NSColor(calibratedWhite: 0.006, alpha: 1)
        let props = SCNNode()
        props.name = "marble-interactive-props"
        scene.rootNode.addChildNode(props)
        let machine = WishMachineScene.reconcileMachineNode(
            in: props,
            worldID: WishMachineScene.worldID,
            drawsWorld: true
        )
        check(machine != nil, "cabin reconciliation provides the machine")

        let ambientNode = SCNNode()
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 125
        ambient.color = NSColor(calibratedRed: 0.90, green: 0.69, blue: 0.48, alpha: 1)
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)
        let keyNode = SCNNode()
        let key = SCNLight()
        key.type = .directional
        key.intensity = 880
        key.color = NSColor(calibratedRed: 1, green: 0.78, blue: 0.56, alpha: 1)
        keyNode.light = key
        keyNode.simdEulerAngles = SIMD3<Float>(-0.72, 0.48, 0)
        scene.rootNode.addChildNode(keyNode)

        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = false
        camera.projectionTransform = SCNMatrix4(perspective(
            fieldOfView: 66 * .pi / 180,
            aspect: Float(width) / Float(height),
            near: 0.05,
            far: 250
        ))
        cameraNode.camera = camera
        let p = config.camera.position
        let cameraPosition = SIMD3<Float>(p[0], p[1], p[2])
        let cameraView = rotationX(-config.camera.pitch)
            * rotationY(-config.camera.yaw)
            * translation(-cameraPosition)
        cameraNode.simdTransform = cameraView.inverse
        scene.rootNode.addChildNode(cameraNode)

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false
        let command = queue.makeCommandBuffer()!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.006, 0.006, 0.006, 1)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 0
        renderer.render(
            atTime: 0,
            viewport: CGRect(x: 0, y: 0, width: width, height: height),
            commandBuffer: command,
            passDescriptor: pass
        )
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        check(command.status == .completed, "offscreen cabin-camera render completes")

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            color.getBytes(
                $0.baseAddress!, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
            )
        }
        var bodyPixels = 0
        var cyanOutlinePixels = 0
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if max(r, max(g, b)) > 22 {
                    bodyPixels += 1
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
                if g > 65 && b > 75 && g > r + 18 && b > r + 18 {
                    cyanOutlinePixels += 1
                }
            }
        }
        check(bodyPixels > 500, "machine body is legible from the actual cabin camera")
        check(cyanOutlinePixels > 12, "machine exposes a distinguishable cyan status/outline strip")
        check(maxX - minX > 22 && maxY - minY > 12, "machine has a recognizable on-screen silhouette")
        print("PASS: wish machine cabin-camera pixels", bodyPixels, "cyan", cyanOutlinePixels, "bounds", minX, minY, maxX, maxY)
    }
}
"""#

let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-wish-body-gpu-\(UUID())")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let source = temp.appendingPathComponent("main.swift")
let executable = temp.appendingPathComponent("check")
try harness.write(to: source, atomically: true, encoding: .utf8)
func run(_ path: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
let result = try run("/usr/bin/nice", [
    "-n", "15", "/usr/bin/swiftc", "-j1", "-swift-version", "6",
    "-target", "arm64-apple-macosx26.0", "-parse-as-library",
    "apps/macos/Sources/GMGNRadio/Presence/WishMachineScene.swift",
    source.path,
    "-framework", "Metal", "-framework", "SceneKit", "-framework", "AppKit",
    "-o", executable.path,
])
guard result == 0 else { exit(result) }
exit(try run(executable.path, []))
