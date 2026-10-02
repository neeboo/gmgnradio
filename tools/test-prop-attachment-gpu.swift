// Offscreen only: a reduced-height copy of the existing generated GLB proves
// the attachment renderer. This fixture does not declare that a coffee
// machine is a valid hand-held product object.
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
let products = root.appendingPathComponent("apps/macos/Build.noindex/Build/Products/Debug")
let attachment = root.appendingPathComponent(
    "apps/macos/Sources/GMGNRadio/Presence/PropAttachment.swift"
)
guard let attachmentSource = try? String(contentsOf: attachment, encoding: .utf8)
else {
    print("FAIL: PropAttachment.swift is missing")
    exit(1)
}

let harness = #"""
import Foundation
import Metal
import simd
// WorldRuntime 的类型不再手写 stub：模块与目标文件由 tools/world-runtime-harness-flags.sh
// 这一处提供（见下方 worldRuntimeHarnessFlags()），`PropAttachment.swift` 也按**真源码**编。
// 手写 stub 的老办法留不住 `WorldQuaternion.identity` / `WorldPropRotation` /
// `WorldPropOrientationPolicy`（`test-prop-attachment.swift` 的文件头记着同一次迁移）。
import WorldRuntime

// 只有 App 侧那几个"世界里的大类型"仍是 stub —— 它们不属于 WorldRuntime，本 harness 也不编它们。
enum StageAvatarFormat: String, Codable, Sendable { case vrm, pmx }
struct StageAvatarAsset: Codable, Equatable, Sendable {
    let id: String; let name: String; let format: StageAvatarFormat
    let modelURL: URL; let resourceRootURL: URL
}
enum StageMotionFormat: String, Codable, Sendable { case procedural, vrma, vmd }
struct StageMotionAsset: Codable, Equatable, Sendable {
    let id: String; let name: String; let format: StageMotionFormat
    let url: URL?; let loop: Bool
    init(id: String, name: String, format: StageMotionFormat, url: URL?, loop: Bool = true) {
        self.id=id;self.name=name;self.format=format;self.url=url;self.loop=loop
    }
}

func check(_ condition: Bool, _ message: String) {
    guard condition else { print("FAIL:", message); exit(1) }
}

@main struct Checks {
    @MainActor static func main() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { throw PropAttachmentError.assetNotPrepared }
        let colorDescription = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 192, height: 192, mipmapped: false
        )
        colorDescription.usage = [.renderTarget]
        colorDescription.storageMode = .shared
        let depthDescription = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 192, height: 192, mipmapped: false
        )
        depthDescription.usage = [.renderTarget]
        depthDescription.storageMode = .private
        let color = device.makeTexture(descriptor: colorDescription)!
        let depth = device.makeTexture(descriptor: depthDescription)!
        let renderer = ResidentPropRenderer(
            device: device, colorFormat: .rgba8Unorm, depthFormat: .depth32Float
        )
        var statuses: [String: WishMachineOutputStatus] = [:]
        renderer.onStatusChanged = { statuses[$0] = $1 }
        let modelURL = URL(
            fileURLWithPath: CommandLine.arguments.dropFirst().first
                ?? "tmp/wish-machine-service-proof-20260906/core/10B3433A-6B1E-43AD-887E-A9F25FC78439.glb"
        )
        let grip = WorldPropGripCalibration(
            avatarAssetID: "pmx.2b-miss-0414-standard", hand: .rightHand,
            normalizedGrip: .init(x: 0.5, y: 0.2, z: 0.5),
            localOffset: .init(x: 0, y: 0, z: 0),
            localRotation: .init(x: 0, y: 0, z: 0, w: 1)
        )
        let held = ResidentHeldPropDescriptor(
            objectID: "held-fixture", worldID: "test", assetID: "00-held",
            modelURL: modelURL, targetHeightMeters: 0.12,
            attachmentPoint: .rightHand, calibration: grip
        )
        renderer.update(
            [], preview: nil, held: held, worldID: "test", isVisible: true
        )
        let prepared = try await renderer.prepare(held)
        check(abs(prepared.size.y - 0.12) < 0.00001, "held asset keeps its adopted metre height")
        check(renderer.assetLoadCount == 1, "held prop uses the resident GLB cache")

        let eye = SIMD3<Float>(0, 0.45, 1.4)
        let f: Float = 1 / tan(50 * Float.pi / 360)
        let near: Float = 0.05, far: Float = 20
        var projection = simd_float4x4()
        projection.columns = (
            SIMD4(f, 0, 0, 0), SIMD4(0, f, 0, 0),
            SIMD4(0, 0, far / (near - far), -1),
            SIMD4(0, 0, far * near / (near - far), 0)
        )
        var view = matrix_identity_float4x4
        view.columns.3 = SIMD4(-eye.x, -eye.y, -eye.z, 1)

        func frame(
            hand: simd_float4x4,
            reverse: Bool = false,
            blocked: Bool = false,
            drawHeld: Bool = true
        ) async throws -> (count: Int, centreX: Float) {
            let command = queue.makeCommandBuffer()!
            let clear = MTLRenderPassDescriptor()
            clear.colorAttachments[0].texture = color
            clear.colorAttachments[0].loadAction = .clear
            clear.colorAttachments[0].storeAction = .store
            clear.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            clear.depthAttachment.texture = depth
            clear.depthAttachment.loadAction = .clear
            clear.depthAttachment.storeAction = .store
            clear.depthAttachment.clearDepth = blocked ? (reverse ? 1 : 0) : (reverse ? 0 : 1)
            command.makeRenderCommandEncoder(descriptor: clear)!.endEncoding()
            if drawHeld {
                _ = try renderer.renderAttachment(
                    handPose: hand, commandBuffer: command,
                    colorTexture: color, depthTexture: depth,
                    viewProjection: projection * view, cameraPosition: eye,
                    reversedDepth: reverse, preservesDepth: true
                )
            } else {
                _ = renderer.render(
                    commandBuffer: command, colorTexture: color, depthTexture: depth,
                    viewProjection: projection * view, cameraPosition: eye,
                    reversedDepth: reverse, preservesDepth: true
                )
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { _ in continuation.resume() }
                command.commit()
            }
            check(command.status == .completed, "offscreen attachment command completes")
            await Task.yield()
            var pixels = [UInt8](repeating: 0, count: 192 * 192 * 4)
            pixels.withUnsafeMutableBytes {
                color.getBytes(
                    $0.baseAddress!, bytesPerRow: 192 * 4,
                    from: MTLRegionMake2D(0, 0, 192, 192), mipmapLevel: 0
                )
            }
            var visible = 0, xTotal = 0
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                if pixels[offset] > 3 || pixels[offset + 1] > 3 || pixels[offset + 2] > 3 {
                    visible += 1
                    xTotal += (offset / 4) % 192
                }
            }
            return (visible, visible == 0 ? 0 : Float(xTotal) / Float(visible))
        }

        var firstHand = matrix_identity_float4x4
        firstHand.columns.3 = SIMD4<Float>(0, 0.35, 0, 1)
        check(try await frame(hand: firstHand, drawHeld: false).count == 0, "held prop is absent from floor placement pass")
        let first = try await frame(hand: firstHand)
        check(first.count > 25, "held GLB is visible at 192 square")
        check(statuses[held.objectID] == .ready(id: held.objectID), "held prop becomes ready only after GPU completion")
        check(try await frame(hand: firstHand, blocked: true).count == 0, "forward depth occludes held prop")
        let reverse = try await frame(hand: firstHand, reverse: true)
        check(abs(reverse.count - first.count) <= 3, "reverse depth keeps the same silhouette")
        check(try await frame(hand: firstHand, reverse: true, blocked: true).count == 0, "reverse depth occludes held prop")
        var secondHand = firstHand
        secondHand.columns.3.x = 0.22
        let second = try await frame(hand: secondHand)
        check(second.centreX > first.centreX + 5, "second frame follows the new evaluated wrist pose")
        check(renderer.assetLoadCount == 1, "two-frame wrist following does not reload GLB")
        let pressure = (1...4).map { index in
            ResidentPropRenderDescriptor(
                objectID: "pressure-\(index)", worldID: "test", assetID: "\(index)0-pressure",
                modelURL: modelURL, targetHeightMeters: 0.12,
                position: SIMD3(Float(index), 0, 0), yaw: 0
            )
        }
        renderer.update(pressure, preview: nil, held: held, worldID: "test", isVisible: true)
        for item in pressure { _ = try await renderer.prepare(item) }
        let transient = ResidentPropRenderDescriptor(
            objectID: "transient", worldID: "test", assetID: "50-transient",
            modelURL: modelURL, targetHeightMeters: 0.12, position: .zero, yaw: 0
        )
        _ = try await renderer.prepare(transient)
        let pressured = try await frame(hand: secondHand)
        check(pressured.count == second.count, "cache pressure cannot evict the visible held GLB")
        renderer.update([], preview: nil, held: held, worldID: "test", isVisible: false)
        check(try await frame(hand: secondHand).count == 0, "hidden non-world surface cannot show held prop")
        print("PASS: held GLB", first.count, "pixels; same cache, two-frame following and both depth modes")
    }
}
"""#

let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
    "gmgn-prop-attachment-gpu-\(UUID().uuidString)"
)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let attachmentCopy = temp.appendingPathComponent("PropAttachment.swift")
let harnessURL = temp.appendingPathComponent("main.swift")
let executableURL = temp.appendingPathComponent("check")
let resourceBundle = products.appendingPathComponent("VRMMetalKit_GLTFMetalKit.bundle")
try FileManager.default.copyItem(
    at: resourceBundle,
    to: temp.appendingPathComponent(resourceBundle.lastPathComponent)
)
// `PropAttachment.swift` 按**真源码**编 —— 不再剥 `import WorldRuntime`。剥掉它就只能靠手写
// stub 顶上，而 stub 留不住 `WorldPropRotation` / `WorldPropOrientationPolicy`。
try attachmentSource.write(to: attachmentCopy, atomically: true, encoding: .utf8)
try harness.write(to: harnessURL, atomically: true, encoding: .utf8)

var objects: [String] = []
let intermediates = root.appendingPathComponent(
    "apps/macos/Build.noindex/Build/Intermediates.noindex/VRMMetalKit.build/Debug"
)
for name in ["GLTFMetalKit", "GLTFCore"] {
    objects += try FileManager.default.contentsOfDirectory(
        at: intermediates.appendingPathComponent("\(name).build/Objects-normal/arm64"),
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "o" }.map(\.path)
}
// 第一项是 `PropSizeIntent` 的**真源码拥有者**（App 侧类型，描述符引用它；本 harness 在 HEAD
// 上就漏了它，与 WorldRuntime 无关）。`PropGripInference.swift` 是 `PropAttachment.swift`
// 现在真正依赖的握点推断（编同一份，不补 stub）。
let sources = [
    "PropGenerationClient.swift", "PropGripInference.swift",
    "WishMachineScene.swift", "WishMachineOutputDescriptor.swift",
    "WishMachineOutputRenderer.swift", "ResidentPropRenderer.swift",
].map { "apps/macos/Sources/GMGNRadio/Presence/" + $0 }

func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

let compile = try run("/usr/bin/nice", [
    "-n", "15", "/usr/bin/swiftc", "-j1", "-swift-version", "6",
    "-target", "arm64-apple-macosx26.0", "-parse-as-library",
] + worldRuntimeHarnessFlags() + [
    // 这里的 `-I products` 是给 GLTFCore / GLTFMetalKit 用的；WorldRuntime 的模块**不**从
    // xcodebuild 产物里取（那份 Debug 是旧物）——它由上面的 worldRuntimeHarnessFlags() 提供，
    // 排在前面所以优先命中。
    "-I", products.path,
] + sources + [attachmentCopy.path, harnessURL.path] + objects + [
    "-framework", "Metal", "-framework", "MetalKit",
    "-framework", "SceneKit", "-framework", "AppKit",
    "-o", executableURL.path,
])
guard compile == 0 else { exit(compile) }
exit(try run(executableURL.path, Array(CommandLine.arguments.dropFirst())))
