import Foundation
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
        if nextHeld != nil, next.count == 4 { next.removeLast() }
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
                let active=Set(desired.map(\.assetKey) + (desiredHeld.map { [$0.assetKey] } ?? []))
                if cache.count+loads.count >= 5,
                   let evict=cache.keys.sorted().first(where: { !active.contains($0) }) { cache.removeValue(forKey:evict) }
                guard cache.count+loads.count < 5 else { throw WishMachineOutputError.renderUnavailable }
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
        _=try ResidentPropPlacementMatrix.transform(minimum:minimum,maximum:maximum,targetHeight:item.targetHeightMeters,position:item.position,yaw:item.yaw)
        let sourceHeight=maximum.y-minimum.y
        return ResidentPropPreparedAsset(minimum:minimum,maximum:maximum,sourceHeight:sourceHeight,size:(maximum-minimum)*(item.targetHeightMeters/sourceHeight))
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
                let transform=try ResidentPropPlacementMatrix.transform(minimum:loaded.asset.worldBounds.min,maximum:loaded.asset.worldBounds.max,targetHeight:item.targetHeightMeters,position:item.position,yaw:item.yaw)
                let calls=loaded.asset.drawCalls.map { GLTFDrawCall(mesh:$0.mesh,material:$0.material,modelMatrix:transform * $0.modelMatrix,skinPalette:$0.skinPalette) }
                loaded.renderer.encodeOpaqueDrawCalls(calls,scene:GLTFSceneState(viewProjection:WishMachineOutputPlacement.projection(viewProjection,reversedDepth:reversedDepth),cameraPosition:cameraPosition),pipelineStates:loaded.pipelines,depthState:reversedDepth ? loaded.reverseDepth : loaded.forwardDepth,encoder:encoder)
            } catch { failed.insert(item.objectID);onStatusChanged?(item.objectID,.failed(id:item.objectID,message:WishMachineOutputError.invalidDimensions.localizedDescription));continue }
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
