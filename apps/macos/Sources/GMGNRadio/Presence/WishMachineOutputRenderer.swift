import Foundation
@preconcurrency import Metal
import GLTFMetalKit
import ImageIO
import simd
import WorldRuntime

/// Uses the pinned VRMMetalKit package's general glTF renderer. No model
/// conversion or per-frame parsing; geometry writes the avatar's depth space.
@MainActor
final class WishMachineOutputRenderer {
    private let device: MTLDevice
    private let colorFormat: MTLPixelFormat
    private let depthFormat: MTLPixelFormat
    private var requested: WishMachineOutputDescriptor?
    private var generation: UInt64 = 0
    private var loadingTask: Task<Void, Never>?
    private var loaded: Loaded?
    private var submittedFirstFrame = false
    var onStatusChanged: (@MainActor (WishMachineOutputStatus) -> Void)?

    init(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) {
        self.device = device; self.colorFormat = colorFormat; self.depthFormat = depthFormat
    }

    deinit { loadingTask?.cancel() }

    func update(_ output: WishMachineOutputDescriptor?, worldID: String?, isVisible: Bool) {
        let next = isVisible && output?.worldID == worldID ? output : nil
        guard next != requested else { return }
        generation &+= 1
        let version = generation
        loadingTask?.cancel(); loadingTask = nil
        requested = next; loaded = nil; submittedFirstFrame = false
        guard let next else { onStatusChanged?(.empty); return }
        onStatusChanged?(.loading(id: next.id))
        let device = device, color = colorFormat, depth = depthFormat
        let work = Task.detached(priority: .utility) {
            try await Loaded.make(output: next, device: device, color: color, depth: depth)
        }
        loadingTask = Task { [weak self] in
            do {
                let result = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: { work.cancel() }
                guard !Task.isCancelled, let self, self.generation == version else { return }
                self.loaded = result
                // Remain loading until one command buffer containing this
                // actual mesh finishes; descriptor assignment is not ready.
            } catch {
                guard !Task.isCancelled, let self, self.generation == version else { return }
                self.loaded = nil
                let message = (error as? WishMachineOutputError)?.localizedDescription
                    ?? WishMachineOutputError.invalidAsset.localizedDescription
                self.onStatusChanged?(.failed(id: next.id, message: message))
            }
        }
    }

    @discardableResult
    func render(commandBuffer: MTLCommandBuffer, colorTexture: MTLTexture, depthTexture: MTLTexture,
                viewProjection: simd_float4x4, cameraPosition: SIMD3<Float>, reversedDepth: Bool,
                preservesDepth: Bool) -> Bool {
        guard let loaded, let requested else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = preservesDepth ? .load : .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = reversedDepth ? 0 : 1
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.label = "Wish machine generated GLB"
        loaded.renderer.encodeOpaqueDrawCalls(
            loaded.calls,
            scene: GLTFSceneState(viewProjection: WishMachineOutputPlacement.projection(viewProjection, reversedDepth: reversedDepth), cameraPosition: cameraPosition),
            pipelineStates: loaded.pipelines,
            depthState: reversedDepth ? loaded.reverseDepth : loaded.forwardDepth,
            encoder: encoder
        )
        encoder.endEncoding()
        if !submittedFirstFrame {
            submittedFirstFrame = true
            let version = generation, id = requested.id
            commandBuffer.addCompletedHandler { [weak self] buffer in
                let succeeded = buffer.status == .completed
                Task { @MainActor [weak self] in
                    guard let self, self.generation == version else { return }
                    if succeeded { self.onStatusChanged?(.ready(id: id)) }
                    else {
                        self.loaded = nil
                        self.onStatusChanged?(.failed(id: id, message: WishMachineOutputError.renderUnavailable.localizedDescription))
                    }
                }
            }
        }
        return true
    }

    /// Constructed on a utility task, then transferred once to the main/render
    /// actor. GLTFAsset lacks Sendable, but no mutable reference is shared with
    /// the loading task after return; all later renderer access is serialized.
    final class Loaded: @unchecked Sendable {
        let asset: GLTFAsset
        let renderer: GLTFRenderer
        let pipelines: GLTFRenderer.PipelineStates
        let calls: [GLTFDrawCall]
        let forwardDepth: MTLDepthStencilState
        let reverseDepth: MTLDepthStencilState
        init(asset: GLTFAsset, renderer: GLTFRenderer, pipelines: GLTFRenderer.PipelineStates,
             calls: [GLTFDrawCall], forwardDepth: MTLDepthStencilState, reverseDepth: MTLDepthStencilState) {
            self.asset = asset; self.renderer = renderer; self.pipelines = pipelines
            self.calls = calls; self.forwardDepth = forwardDepth; self.reverseDepth = reverseDepth
        }

        static func make(output: WishMachineOutputDescriptor, device: MTLDevice,
                         color: MTLPixelFormat, depth: MTLPixelFormat) async throws -> Loaded {
            guard output.modelURL.isFileURL, output.modelURL.pathExtension.lowercased() == "glb",
                  let bytes = try output.modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  bytes > 20, bytes <= 32 * 1024 * 1024
            else { throw WishMachineOutputError.invalidAsset }
            try Task.checkCancellation()
            let data = try Data(contentsOf: output.modelURL)
            let parsed = try GLTFParser().parse(data: data, filePath: output.modelURL.path)
            // Service outputs must be self-contained. Never follow a texture
            // URL or a relative file reference from a generated asset.
            guard (parsed.document.buffers ?? []).allSatisfy({ $0.uri == nil }),
                  (parsed.document.images ?? []).allSatisfy({ $0.uri == nil })
            else { throw WishMachineOutputError.invalidAsset }
            let requiredTextureCount = try WishMachineTexturePolicy.validate(document: parsed.document, binaryData: parsed.binaryData)
            let asset = try await GLTFAssetLoader().build(document: parsed.document, binaryData: parsed.binaryData, baseURL: nil, device: device)
            try Task.checkCancellation()
            try WishMachineTexturePolicy.validateLoadedTextureCount(asset.textures.count, required: requiredTextureCount)
            guard !asset.drawCalls.isEmpty else { throw WishMachineOutputError.invalidAsset }
            // 出货口来自世界包声明（`outlet` 功能点）。声明缺失 ⇒ 没有出货口 ⇒ 不渲染，
            // 而不是退回到一组写死的坐标。
            guard let outlet = WishMachineScene.outletPosition else {
                throw WishMachineOutputError.renderUnavailable
            }
            // 托盘上那一件还没登记，`targetHeightMeters` 是**生成请求**的高度 ⇒ 先过一次
            // 唯一那份尺度策略（细长物件按最长边归一），把"请求高度"落成**世界高度**；
            // 已登记物件（`heightIsGenerationRequest == false`）拿到的已经是定稿高度，
            // 策略**不重复应用**（它不幂等：重复套用会把细长物件每帧再缩一次）。
            let extent = asset.worldBounds.max - asset.worldBounds.min
            let requested = output.targetHeightMeters
            let resolvedHeight: Float
            /// 托盘预览要用的**逐轴**目标尺寸；nil = 等比（既有产物逐位不变）。
            var resolvedSize: WorldVector3?
            if output.heightIsGenerationRequest {
                // **有尺寸意图就按用户说的那根轴归一**（"一把 1.1 米的剑"= 最长边 1.1 m），
                // 没有意图才退回今天的自动推断（细长物件按最长边）。两条路共用同一份策略、
                // 同一段上下限夹取 —— 面板、碰撞盒、红绿格读到的仍是同一份尺寸。
                let resolution: WorldPropSizePolicy.Resolution?
                // 归一是**按哪一条**判据做的、那个数是多少：具名拒绝要用它，所以两条路都先记下来。
                let basisField: String
                let basisMeters: Float
                if let intent = output.sizeIntent, intent.isValid {
                    let worldExtent = WorldVector3(x: extent.x, y: extent.y, z: extent.z)
                    basisField = "size_intent.\(intent.axis.rawValue).meters"
                    basisMeters = Float(intent.meters)
                    // **完整三轴**：三个数就是三个数（与入库那一处读**同一个裁决**
                    // `dimensionsVerdict`，所以预览与最终产物不可能长得不一样）。
                    // 形状差得太远时裁决是 `.shapeTooFar` ⇒ 这里**不拉**，退回单轴那一份
                    // （可见的两条路由入库那一处说给用户）。
                    if intent.mode == .dimensions, let millimeters = intent.millimeters,
                       let spec = WorldPropSizeMillimeters(x: Float(millimeters.x),
                                                           y: Float(millimeters.y),
                                                           z: Float(millimeters.z)),
                       case let .exact(exact) = WorldPropSizePolicy.dimensionsVerdict(
                           sourceExtent: worldExtent, millimeters: spec) {
                        resolution = exact
                        resolvedSize = exact.size
                    } else {
                        resolution = WorldPropSizePolicy.intended(
                            sourceExtent: worldExtent,
                            axis: intent.axis.policyAxis, meters: Float(intent.meters))
                    }
                } else {
                    resolution = WorldPropSizePolicy.automatic(
                        sourceExtent: .init(x: extent.x, y: extent.y, z: extent.z),
                        requestedHeight: requested)
                    basisField = "height_meters"
                    basisMeters = requested
                }
                guard let resolution else {
                    // **字段级**具名拒绝（新纪律）。真机 2026-10-02「超大荧幕电视」就停在这里：
                    // 三轴意图派生的 `meters` 是 `1443`（毫米被当成米），归一策略只接受
                    // `0.01—100` 米 ⇒ 归不出来。原来这一句只有"尺寸无效"，字段与数字一个都没有，
                    // 于是那台电视"加载失败"查不出是哪一条判据、哪个数。
                    throw WishMachineOutputError.invalidDimensions(WishMachineDimensionRejection(
                        field: basisField, value: basisMeters,
                        expected: "0.01—100 米，且源网格三轴都必须是 > 0 的有限数（实测源网格 "
                            + "\(WishMachineDimensionRejection.text(extent.x)) × "
                            + "\(WishMachineDimensionRejection.text(extent.y)) × "
                            + "\(WishMachineDimensionRejection.text(extent.z)) 米）"))
                }
                resolvedHeight = resolution.size.y
            } else {
                resolvedHeight = requested
            }
            let transform = try WishMachineOutputPlacement.transform(
                minimum: asset.worldBounds.min, maximum: asset.worldBounds.max,
                targetHeight: resolvedHeight, targetSize: resolvedSize, outlet: outlet
            )
            let calls = asset.drawCalls.map { GLTFDrawCall(mesh: $0.mesh, material: $0.material, modelMatrix: transform * $0.modelMatrix, skinPalette: $0.skinPalette) }
            let renderer = try GLTFRenderer(device: device)
            let pipelines = try renderer.makePipelineStates(colorFormat: color, depthFormat: depth)
            func makeDepth(_ compare: MTLCompareFunction) throws -> MTLDepthStencilState {
                let descriptor = MTLDepthStencilDescriptor()
                descriptor.depthCompareFunction = compare; descriptor.isDepthWriteEnabled = true
                guard let value = device.makeDepthStencilState(descriptor: descriptor) else { throw WishMachineOutputError.renderUnavailable }
                return value
            }
            return Loaded(asset: asset, renderer: renderer, pipelines: pipelines, calls: calls,
                          forwardDepth: try makeDepth(.less), reverseDepth: try makeDepth(.greater))
        }
    }
}

extension PropSizeIntent.Axis {
    /// 提交契约的轴 → 世界尺度策略的轴。两边的字面量本来就相同，所以这里只是**唯一**一处
    /// 搬运：谁要消费意图，都必须经过它，而不是各自再写一遍 `if axis == "longest"`。
    var policyAxis: WorldPropSizeAxis {
        switch self {
        case .longest: return .longest
        case .height: return .height
        }
    }
}

/// Metadata-only preflight before the pinned loader starts parallel decoding.
/// Count texture references (not unique images): two texture indices can cause
/// two independent uploads even when they reference the same encoded image.
enum WishMachineTexturePolicy {
    static let maximumDimension = 2048
    static let maximumTotalPixels = 16_000_000
    static let maximumTextures = 8

    static func validate(document: GLTFDocument, binaryData: Data?) throws -> Int {
        var indices = Set<Int>()
        for material in document.materials ?? [] {
            [material.pbrMetallicRoughness?.baseColorTexture?.index,
             material.pbrMetallicRoughness?.metallicRoughnessTexture?.index,
             material.normalTexture?.index, material.occlusionTexture?.index,
             material.emissiveTexture?.index].compactMap { $0 }.forEach { indices.insert($0) }
        }
        guard indices.count <= maximumTextures else { throw WishMachineOutputError.textureBudget }
        let textures = document.textures ?? [], images = document.images ?? [], views = document.bufferViews ?? []
        var totalPixels = 0
        for index in indices {
            guard textures.indices.contains(index), let sourceIndex = textures[index].source,
                  images.indices.contains(sourceIndex), images[sourceIndex].uri == nil,
                  let viewIndex = images[sourceIndex].bufferView, views.indices.contains(viewIndex),
                  let binaryData else { throw WishMachineOutputError.invalidTexture }
            let view = views[viewIndex], offset = view.byteOffset ?? 0
            guard view.buffer == 0, offset >= 0, offset <= binaryData.count,
                  view.byteLength > 0, view.byteLength <= binaryData.count-offset
            else { throw WishMachineOutputError.invalidTexture }
            let bytes = binaryData.subdata(in: offset..<(offset+view.byteLength))
            guard let image = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let type = CGImageSourceGetType(image) as String?, ["public.png","public.jpeg"].contains(type),
                  CGImageSourceGetCount(image) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString:Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0
            else { throw WishMachineOutputError.invalidTexture }
            guard width <= maximumDimension, height <= maximumDimension else { throw WishMachineOutputError.textureBudget }
            totalPixels += width*height
            guard totalPixels <= maximumTotalPixels else { throw WishMachineOutputError.textureBudget }
        }
        return indices.count
    }

    static func validateLoadedTextureCount(_ actual: Int, required: Int) throws {
        // The fixed loader retains exactly textureMap.values for the same set
        // of referenced indices above. A swallowed decode/upload failure must
        // therefore make this count smaller; default white is not a success.
        guard actual == required else { throw WishMachineOutputError.invalidTexture }
    }
}
