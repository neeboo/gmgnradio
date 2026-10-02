import Foundation
import WorldRuntime
@preconcurrency import Metal
import GLTFMetalKit
import simd

/// Owns GPU assets separately from placements. Moving a preview only changes
/// matrices; shared assets retain one parser/texture upload per visible world.
@MainActor final class ResidentPropRenderer {
    private let device: MTLDevice
    private let colorFormat: MTLPixelFormat
    private let depthFormat: MTLPixelFormat
    private var worldID: String?
    private var generation: UInt64 = 0
    private var desired: [ResidentPropRenderDescriptor] = []
    private var desiredHeld: ResidentHeldPropDescriptor?
    private var cache: [String: WishMachineOutputRenderer.Loaded] = [:]
    private var loads: [String: Task<WishMachineOutputRenderer.Loaded, Error>] = [:]
    private var objectLoads: [String: Task<Void, Never>] = [:]
    private var submitted = Set<String>()
    private var failed = Set<String>()
    private(set) var assetLoadCount = 0
    /// 已解析 GLB 资产的预算。每个资产是一次完整解析 + 纹理上传，所以必须有上限；
    /// 但**预算只决定"先画谁"，绝不决定"能不能放"**：能放多少由世界模型说了算，
    /// 渲染端预算不足时只是这一帧不画，等资产被释放后自然补上。
    static let assetBudget = 32
    /// 同时进行的 GLB 解析上限。一次放下 30 件时不应该同时解析 30 个 GLB。
    static let maximumConcurrentLoads = 4
    /// 当前被需要的资产键（已摆放 + 手持）。
    private var activeAssetKeys: Set<String> {
        Set(desired.map(\.assetKey) + (desiredHeld.map { [$0.assetKey] } ?? []))
    }
    var onStatusChanged: (@MainActor (String, WishMachineOutputStatus) -> Void)?

    init(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) {
        self.device=device;self.colorFormat=colorFormat;self.depthFormat=depthFormat
    }
    deinit { loads.values.forEach { $0.cancel() };objectLoads.values.forEach { $0.cancel() } }

    func isPrepared(assetID: String, modelURL: URL, worldID expectedWorldID: String? = nil) -> Bool {
        worldID != nil && (expectedWorldID == nil || expectedWorldID == worldID)
            && cache[assetID + "|" + modelURL.standardizedFileURL.path] != nil
    }

    func update(
        _ objects: [ResidentPropRenderDescriptor],
        preview: ResidentPropRenderDescriptor?,
        held: ResidentHeldPropDescriptor? = nil,
        worldID: String?,
        isVisible: Bool
    ) {
        let nextWorld = isVisible ? worldID : nil
        if self.worldID != nextWorld {
            generation &+= 1
            loads.values.forEach { $0.cancel() };loads.removeAll()
            objectLoads.values.forEach { $0.cancel() };objectLoads.removeAll()
            cache.removeAll();submitted.removeAll();failed.removeAll()
            for item in desired { onStatusChanged?(item.objectID,.empty) }
            if let desiredHeld { onStatusChanged?(desiredHeld.objectID, .empty) }
            desired=[];desiredHeld=nil;self.worldID=nextWorld
        }
        var next = ResidentPropRenderSelection.resolve(objects, preview: preview, worldID: nextWorld)
        let nextHeld = held.flatMap { $0.worldID == nextWorld ? $0 : nil }
        // 手持与已摆放各自计数。旧代码在手持时会砍掉最后一件已摆放物件，
        // 用户看到的是"我摆的家具自己消失了"——静默丢数据，不再保留该行为。
        let previous = Dictionary(uniqueKeysWithValues: desired.map { ($0.objectID,$0.assetKey) })
            .merging(desiredHeld.map { [$0.objectID: $0.assetKey] } ?? [:]) { _, new in new }
        desired=next;desiredHeld=nextHeld
        let heldItems = nextHeld.map(Self.renderDescriptor(for:)).map { [$0] } ?? []
        let loadItems = next + heldItems
        let nextIDs = Set(loadItems.map(\.objectID))
        for id in objectLoads.keys.filter({ !nextIDs.contains($0) }) { objectLoads.removeValue(forKey:id)?.cancel() }
        for id in previous.keys where !nextIDs.contains(id) {
            submitted.remove(id);failed.remove(id);onStatusChanged?(id,.empty)
        }
        for item in loadItems {
            if previous[item.objectID] != item.assetKey { submitted.remove(item.objectID);failed.remove(item.objectID) }
            if cache[item.assetKey] == nil { submitted.remove(item.objectID) }
            guard !submitted.contains(item.objectID), !failed.contains(item.objectID), objectLoads[item.objectID] == nil else { continue }
            // 预算 / 并发闸门：超了就**本帧不加载**，下次 update 会自然重试。
            // 刻意不抛错 —— 抛错会被上面的 catch 标成 failed，那件家具就永远画不出来了。
            Self.makeRoom(cache: &cache, active: activeAssetKeys)
            guard cache.count + loads.count < Self.assetBudget,
                  objectLoads.count < Self.maximumConcurrentLoads else { continue }
            onStatusChanged?(item.objectID,.loading(id:item.objectID))
            if cache[item.assetKey] != nil { continue }
            let epoch=generation
            objectLoads[item.objectID]=Task { [weak self] in
                guard let self else { return }
                defer { if self.generation == epoch { self.objectLoads[item.objectID]=nil } }
                do { _=try await self.prepare(item) }
                catch {
                    guard !Task.isCancelled, self.generation == epoch,
                          self.desired.contains(where: { $0.objectID==item.objectID && $0.assetKey==item.assetKey })
                            || self.desiredHeld.map({ $0.objectID == item.objectID && $0.assetKey == item.assetKey }) == true
                    else { return }
                    self.failed.insert(item.objectID)
                    self.onStatusChanged?(item.objectID,.failed(id:item.objectID,message:(error as? WishMachineOutputError)?.localizedDescription ?? WishMachineOutputError.invalidAsset.localizedDescription))
                }
            }
        }
    }

    /// 为即将加载的资产腾位置。
    ///
    /// **只淘汰当前不需要的资产**（按资产键排序，保证确定性）。刻意不淘汰"当前需要
    /// 但距离较远"的资产：那会让它在下一帧被重新加载，和本次要加载的资产来回抖动
    /// （每帧一次完整 GLB 解析）。所以预算真的用尽时，调用方选择"这一帧不画"，
    /// 等资产自然释放（收回物件、切换空间、退出编辑器）后补上。
    static func makeRoom(
        cache: inout [String: WishMachineOutputRenderer.Loaded],
        active: Set<String>
    ) {
        guard cache.count >= assetBudget else { return }
        for key in cache.keys.filter({ !active.contains($0) }).sorted() {
            cache.removeValue(forKey: key)
            if cache.count < assetBudget { return }
        }
    }

    func prepare(_ item: ResidentHeldPropDescriptor) async throws -> ResidentPropPreparedAsset {
        try await prepare(Self.renderDescriptor(for: item))
    }

    /// Validated resources are prepared only. This does not place an object or
    /// emit GPU-ready; callers still commit through the world placement service.
    func prepare(_ item: ResidentPropRenderDescriptor) async throws -> ResidentPropPreparedAsset {
        guard worldID == item.worldID else { throw CancellationError() }
        let epoch=generation,key=item.assetKey
        let asset: WishMachineOutputRenderer.Loaded
        if let existing=cache[key] { asset=existing }
        else {
            if loads[key] == nil {
                Self.makeRoom(cache: &cache, active: activeAssetKeys)
                // 兜底：update 已经做过预算闸门，正常路径不会走到这里。直接调用
                // prepare 的外部路径仍然得到可见失败，而不是静默不加载。
                guard cache.count+loads.count < Self.assetBudget else { throw WishMachineOutputError.renderUnavailable }
                let device=device,color=colorFormat,depth=depthFormat
                let output=WishMachineOutputDescriptor(id:item.objectID,worldID:item.worldID,modelURL:item.modelURL,targetHeightMeters:item.targetHeightMeters)
                assetLoadCount += 1
                loads[key]=Task.detached(priority:.utility) { try await WishMachineOutputRenderer.Loaded.make(output:output,device:device,color:color,depth:depth) }
            }
            guard let task=loads[key] else { throw CancellationError() }
            do { asset=try await task.value }
            catch { if generation==epoch { loads.removeValue(forKey:key) };throw error }
            guard generation==epoch,worldID==item.worldID else { throw CancellationError() }
            cache[key]=asset;loads.removeValue(forKey:key)
        }
        try Task.checkCancellation()
        let minimum=asset.asset.worldBounds.min,maximum=asset.asset.worldBounds.max
        _=try ResidentPropPlacementMatrix.transform(minimum:minimum,maximum:maximum,targetHeight:item.targetHeightMeters,position:item.position,yaw:item.yaw,orientation:item.orientation)
        // `sourceHeight` 与 `size` 都是**摆正之后**的那一份：`WorldSimulation` 用
        // `size.y / sourceHeight` 算物件自己的等比缩放，渲染矩阵也按摆正后的高度归一 ——
        // 两处必须是同一个数，否则画面与存档各缩各的。躺着的网格（真机那把剑）在这一步
        // 从"原始 Y 跨度 0.133"变成"摆正后高度 1.005"，于是 1.1 m 的请求就是一把立着的
        // 1.1 m 剑，而不是 8.28 m 长的横棍。
        let oriented = WorldPropOrientationPolicy.orientedBounds(
            minimum: minimum, maximum: maximum, rotation: item.orientation
        )
        let orientedExtent = oriented.maximum - oriented.minimum
        let sourceHeight = orientedExtent.y
        guard sourceHeight.isFinite, sourceHeight > 0.000_01 else {
            throw WishMachineOutputError.invalidDimensions(WishMachineDimensionRejection(
                field: "sourceHeight（摆正后网格的高度）", value: sourceHeight,
                expected: "> 0.00001 米（实测摆正后 y 从 "
                    + "\(WishMachineDimensionRejection.text(oriented.minimum.y)) 到 "
                    + "\(WishMachineDimensionRejection.text(oriented.maximum.y)) 米）"))
        }
        // 只按高度轴归一的尺寸（见 `ResidentPropPreparedAsset.size` 的说明）：真正的自动
        // 尺寸由 `WorldPropSizePolicy` 在**拿到生成请求高度的那一处**算出（细长物件按最长边
        // 归一）。渲染端不重复应用策略 —— 它拿到的 targetHeight 已经是定稿高度。
        return ResidentPropPreparedAsset(minimum:minimum,maximum:maximum,sourceHeight:sourceHeight,size:orientedExtent*(item.targetHeightMeters/sourceHeight))
    }

    @discardableResult func render(commandBuffer: MTLCommandBuffer, colorTexture: MTLTexture, depthTexture: MTLTexture,
                                  viewProjection: simd_float4x4, cameraPosition: SIMD3<Float>, reversedDepth: Bool,
                                  preservesDepth: Bool) -> Bool {
        let drawable=desired.filter { cache[$0.assetKey] != nil && !failed.contains($0.objectID) }
        guard !drawable.isEmpty else { return false }
        let pass=MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture=colorTexture;pass.colorAttachments[0].loadAction = .load;pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture=depthTexture;pass.depthAttachment.loadAction = preservesDepth ? .load : .clear
        pass.depthAttachment.storeAction = .store;pass.depthAttachment.clearDepth=reversedDepth ? 0 : 1
        guard let encoder=commandBuffer.makeRenderCommandEncoder(descriptor:pass) else { return false }
        encoder.label="Resident placed GLB objects"
        for item in drawable {
            guard let loaded=cache[item.assetKey] else { continue }
            do {
                let transform=try ResidentPropPlacementMatrix.transform(minimum:loaded.asset.worldBounds.min,maximum:loaded.asset.worldBounds.max,targetHeight:item.targetHeightMeters,position:item.position,yaw:item.yaw,orientation:item.orientation)
                let calls=loaded.asset.drawCalls.map { GLTFDrawCall(mesh:$0.mesh,material:$0.material,modelMatrix:transform * $0.modelMatrix,skinPalette:$0.skinPalette) }
                loaded.renderer.encodeOpaqueDrawCalls(calls,scene:GLTFSceneState(viewProjection:WishMachineOutputPlacement.projection(viewProjection,reversedDepth:reversedDepth),cameraPosition:cameraPosition),pipelineStates:loaded.pipelines,depthState:reversedDepth ? loaded.reverseDepth : loaded.forwardDepth,encoder:encoder)
            } catch {
                // 拒绝的理由就是**这一条**判据自己说的那句（字段 + 数值）：它原来在这里被换成
                // 一句写死的"尺寸无效"，连抛出来的原因都不看 —— 现场能拿到的信息又少一层。
                failed.insert(item.objectID)
                onStatusChanged?(item.objectID,.failed(id:item.objectID,message:error.localizedDescription))
                continue
            }
            if submitted.insert(item.objectID).inserted {
                let epoch=generation
                commandBuffer.addCompletedHandler { [weak self] buffer in
                    let succeeded=buffer.status == .completed
                    Task { @MainActor [weak self] in
                        guard let self,self.generation==epoch,self.desired.contains(where: { $0.objectID==item.objectID && $0.assetKey==item.assetKey }) else { return }
                        if !succeeded { self.failed.insert(item.objectID) }
                        self.onStatusChanged?(item.objectID,succeeded ? .ready(id:item.objectID) : .failed(id:item.objectID,message:WishMachineOutputError.renderUnavailable.localizedDescription))
                    }
                }
            }
        }
        encoder.endEncoding()
        return true
    }

    @discardableResult func renderAttachment(
        handPose: simd_float4x4,
        commandBuffer: MTLCommandBuffer,
        colorTexture: MTLTexture,
        depthTexture: MTLTexture,
        viewProjection: simd_float4x4,
        cameraPosition: SIMD3<Float>,
        reversedDepth: Bool,
        preservesDepth: Bool
    ) throws -> Bool {
        guard let item = desiredHeld else { return false }
        guard !failed.contains(item.objectID), let loaded = cache[item.assetKey]
        else { throw PropAttachmentError.assetNotPrepared }
        let transform = try PropAttachmentMatrix.transform(
            minimum: loaded.asset.worldBounds.min,
            maximum: loaded.asset.worldBounds.max,
            descriptor: item,
            handPose: handPose
        )
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = preservesDepth ? .load : .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = reversedDepth ? 0 : 1
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { return false }
        encoder.label = "Resident held GLB object"
        let calls = loaded.asset.drawCalls.map {
            GLTFDrawCall(
                mesh: $0.mesh,
                material: $0.material,
                modelMatrix: transform * $0.modelMatrix,
                skinPalette: $0.skinPalette
            )
        }
        loaded.renderer.encodeOpaqueDrawCalls(
            calls,
            scene: GLTFSceneState(
                viewProjection: WishMachineOutputPlacement.projection(
                    viewProjection,
                    reversedDepth: reversedDepth
                ),
                cameraPosition: cameraPosition
            ),
            pipelineStates: loaded.pipelines,
            depthState: reversedDepth ? loaded.reverseDepth : loaded.forwardDepth,
            encoder: encoder
        )
        encoder.endEncoding()
        if submitted.insert(item.objectID).inserted {
            let epoch = generation
            commandBuffer.addCompletedHandler { [weak self] buffer in
                let succeeded = buffer.status == .completed
                Task { @MainActor [weak self] in
                    guard let self,
                          self.generation == epoch,
                          self.desiredHeld?.objectID == item.objectID,
                          self.desiredHeld?.assetKey == item.assetKey
                    else { return }
                    if !succeeded { self.failed.insert(item.objectID) }
                    self.onStatusChanged?(
                        item.objectID,
                        succeeded
                            ? .ready(id: item.objectID)
                            : .failed(
                                id: item.objectID,
                                message: WishMachineOutputError.renderUnavailable
                                    .localizedDescription
                            )
                    )
                }
            }
        }
        return true
    }

    private static func renderDescriptor(
        for held: ResidentHeldPropDescriptor
    ) -> ResidentPropRenderDescriptor {
        ResidentPropRenderDescriptor(
            objectID: held.objectID,
            worldID: held.worldID,
            assetID: held.assetID,
            modelURL: held.modelURL,
            targetHeightMeters: held.targetHeightMeters,
            position: .zero,
            yaw: 0
        )
    }
}
