@preconcurrency import MetalKit

enum StageRendererError: Error {
    case missingCommandQueue
    case missingShaderLibrary
    case missingShaderFunction(String)
    case missingVertexBuffer
    case missingDepthState
    case missingArtworkTexture
}

@MainActor
final class StageRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let backgroundPipeline: MTLRenderPipelineState
    private let ambientParticlePipeline: MTLRenderPipelineState
    private let particleBloomPipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let vertexBuffer: MTLBuffer
    private let vertexCount: Int
    private let ambientVertexBuffer: MTLBuffer
    private let ambientVertexCount: Int
    private let audioFeatures: VisualAudioFeatureStore
    private let artwork: StageArtworkStore
    private let visualDirections: StageVisualDirectionStore
    private let videos: StageVideoPlaybackStore
    private let textureLoader: MTKTextureLoader
    private let fallbackArtworkTexture: MTLTexture
    private var artworkTexture: MTLTexture
    private var observedArtworkRevision: UInt64 = .max
    private var hasArtwork = false
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant
    private var previousFrameAt: ContinuousClock.Instant
    private var camera = StageCameraModel()
    private let presetTimeline = StageVisualPresetTimeline()
    private var hasObservedVisualDirection = false
    private var observedVisualMood: StageVisualMood?
    private var observedVisualPalette: StageVisualPalette?
    private var observedPointCloudChoice: StagePointCloudChoice = .automatic
    private var presetTransitionStartedAt: Float?
    private var presetTransitionOrigin = SIMD3<Float>(1, 0, 0)
    private var displayedPresetWeights = SIMD3<Float>(1, 0, 0)
    private var compositionTransitionOrigin: Float = 0
    private var displayedComposition: Float = 0
    private var paletteTransitionOrigin = StageVisualPalette.amber
    private var displayedPalette = StageVisualPalette.amber
    private var rhythmResponse = StageRhythmResponse()

    init(
        device: MTLDevice,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat,
        audioFeatures: VisualAudioFeatureStore,
        artwork: StageArtworkStore,
        visualDirections: StageVisualDirectionStore,
        videos: StageVideoPlaybackStore
    ) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw StageRendererError.missingCommandQueue
        }
        let artworkDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        artworkDescriptor.usage = [.shaderRead]
        guard let fallbackArtworkTexture = device.makeTexture(
            descriptor: artworkDescriptor
        ) else {
            throw StageRendererError.missingArtworkTexture
        }
        var fallbackPixel: UInt32 = 0xFFFF_4010
        fallbackArtworkTexture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &fallbackPixel,
            bytesPerRow: MemoryLayout<UInt32>.stride
        )
        guard let library = device.makeDefaultLibrary() else {
            throw StageRendererError.missingShaderLibrary
        }

        backgroundPipeline = try Self.makePipeline(
            device: device,
            library: library,
            vertexFunction: "stageBackgroundVertex",
            fragmentFunction: "stageBackgroundFragment",
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: .invalid,
            blending: false
        )
        ambientParticlePipeline = try Self.makePipeline(
            device: device,
            library: library,
            vertexFunction: "stageAmbientParticleVertex",
            fragmentFunction: "stageAmbientParticleFragment",
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat,
            blending: true,
            additive: true
        )
        particleBloomPipeline = try Self.makePipeline(
            device: device,
            library: library,
            vertexFunction: "stageParticleVertex",
            fragmentFunction: "stageParticleBloomFragment",
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat,
            blending: true,
            additive: true
        )
        particlePipeline = try Self.makePipeline(
            device: device,
            library: library,
            vertexFunction: "stageParticleVertex",
            fragmentFunction: "stageParticleFragment",
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat,
            blending: true
        )

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(
            descriptor: depthDescriptor
        ) else {
            throw StageRendererError.missingDepthState
        }

        let geometry = StageParticleGeometry.albumCanvas(
            grid: 144,
            seed: 0x474D474E
        )
        let buffer = geometry.vertices.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return nil as MTLBuffer?
            }
            return device.makeBuffer(
                bytes: baseAddress,
                length: bytes.count,
                options: .storageModeShared
            )
        }
        guard let buffer else {
            throw StageRendererError.missingVertexBuffer
        }
        buffer.label = "gmgn radio DJ particle geometry"

        let ambientGeometry = StageParticleGeometry.ambientField(
            count: 1_800,
            seed: 0x4D564658
        )
        let ambientBuffer = ambientGeometry.vertices.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return nil as MTLBuffer?
            }
            return device.makeBuffer(
                bytes: baseAddress,
                length: bytes.count,
                options: .storageModeShared
            )
        }
        guard let ambientBuffer else {
            throw StageRendererError.missingVertexBuffer
        }
        ambientBuffer.label = "gmgn radio layered ambient particles"

        self.commandQueue = commandQueue
        self.depthState = depthState
        vertexBuffer = buffer
        vertexCount = geometry.vertices.count
        ambientVertexBuffer = ambientBuffer
        ambientVertexCount = ambientGeometry.vertices.count
        self.audioFeatures = audioFeatures
        self.artwork = artwork
        self.visualDirections = visualDirections
        self.videos = videos
        textureLoader = MTKTextureLoader(device: device)
        self.fallbackArtworkTexture = fallbackArtworkTexture
        artworkTexture = fallbackArtworkTexture
        startedAt = clock.now
        previousFrameAt = startedAt
        super.init()
    }

    func beginDrag() {
        camera.beginDrag()
    }

    func drag(deltaX: Float, deltaY: Float) {
        camera.drag(deltaX: deltaX, deltaY: deltaY)
    }

    func endDrag() {
        camera.endDrag()
    }

    func resetCamera() {
        camera = StageCameraModel()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = clock.now
        let deltaTime = Self.seconds(previousFrameAt.duration(to: now))
        previousFrameAt = now
        camera.step(
            deltaTime: deltaTime,
            autoOrbitEnabled:
                visualDirections.currentPointCloudChoice.allowsAutoOrbit
        )

        guard
            let drawable = view.currentDrawable,
            let descriptor = view.currentRenderPassDescriptor,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: descriptor
            )
        else {
            return
        }

        let elapsed = Self.seconds(startedAt.duration(to: now))
        let presetFrame = resolvePresetFrame(at: elapsed)
        let presetWeights = presetFrame.weights
        refreshArtworkTexture()
        let reactiveAudio = rhythmResponse.update(
            audio: audioFeatures.current,
            deltaTime: deltaTime
        )
        let compositing: StageCompositingProfile = videos.isActive
            ? .video
            : .standard
        let pointLayers = StagePointLayerPolicy.resolve(
            choice: visualDirections.currentPointCloudChoice,
            videoActive: videos.isActive
        )
        var uniforms = StageUniforms.make(
            camera: camera.frame,
            audio: reactiveAudio,
            time: elapsed,
            viewport: SIMD2<Float>(
                Float(view.drawableSize.width),
                Float(view.drawableSize.height)
            ),
            presetWeights: presetWeights,
            composition: presetFrame.composition,
            palette: displayedPalette,
            visualIntensity: visualDirections.currentIntensity,
            compositing: compositing,
            pointLayers: pointLayers
        )
        uniforms.viewportAndMotion.w = hasArtwork ? 1 : 0

        encoder.label = "gmgn radio 360 stage"
        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<StageUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 3
        )

        encoder.setRenderPipelineState(ambientParticlePipeline)
        encoder.setDepthStencilState(nil)
        encoder.setVertexBuffer(ambientVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<StageUniforms>.stride,
            index: 1
        )
        encoder.drawPrimitives(
            type: .point,
            vertexStart: 0,
            vertexCount: ambientVertexCount
        )

        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<StageUniforms>.stride,
            index: 1
        )
        encoder.setVertexTexture(artworkTexture, index: 0)
        encoder.setRenderPipelineState(particleBloomPipeline)
        encoder.setDepthStencilState(nil)
        encoder.drawPrimitives(
            type: .point,
            vertexStart: 0,
            vertexCount: vertexCount
        )

        encoder.setRenderPipelineState(particlePipeline)
        encoder.setDepthStencilState(depthState)
        encoder.drawPrimitives(
            type: .point,
            vertexStart: 0,
            vertexCount: vertexCount
        )
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func refreshArtworkTexture() {
        guard artwork.revision != observedArtworkRevision else {
            return
        }
        observedArtworkRevision = artwork.revision

        guard let image = artwork.image else {
            artworkTexture = fallbackArtworkTexture
            hasArtwork = false
            return
        }
        do {
            artworkTexture = try textureLoader.newTexture(
                cgImage: image,
                options: [
                    .SRGB: false,
                    .textureUsage: NSNumber(
                        value: MTLTextureUsage.shaderRead.rawValue
                    )
                ]
            )
            hasArtwork = true
        } catch {
            artworkTexture = fallbackArtworkTexture
            hasArtwork = false
        }
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertexFunction: String,
        fragmentFunction: String,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat,
        blending: Bool,
        additive: Bool = false
    ) throws -> MTLRenderPipelineState {
        guard let vertex = library.makeFunction(name: vertexFunction) else {
            throw StageRendererError.missingShaderFunction(vertexFunction)
        }
        guard let fragment = library.makeFunction(name: fragmentFunction) else {
            throw StageRendererError.missingShaderFunction(fragmentFunction)
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "gmgn radio \(fragmentFunction)"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat

        if blending, let attachment = descriptor.colorAttachments[0] {
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = additive
                ? .one
                : .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = additive
                ? .one
                : .oneMinusSourceAlpha
        }

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func resolvePresetFrame(
        at time: Float
    ) -> StageVisualPresetFrame {
        let automaticFrame = presetTimeline.sample(at: time)
        let automaticWeights = automaticFrame.weights
        let automaticPalette = StageVisualPalette.blended(
            for: automaticWeights
        )
        let requestedMood = visualDirections.currentMood
        let requestedPalette = visualDirections.currentPalette
        let requestedPointCloudChoice =
            visualDirections.currentPointCloudChoice
        let directedFrame = requestedMood.map(
            StageVisualPresetFrame.forMood
        ) ?? automaticFrame
        let resolvedFrame = requestedPointCloudChoice.resolvedPresetFrame(
            automatic: directedFrame
        )

        if !hasObservedVisualDirection {
            hasObservedVisualDirection = true
            observedVisualMood = requestedMood
            observedVisualPalette = requestedPalette
            observedPointCloudChoice = requestedPointCloudChoice
            let initialFrame = resolvedFrame
            displayedPresetWeights = initialFrame.weights
            displayedComposition = initialFrame.composition
            displayedPalette = requestedPalette ?? automaticPalette
            return StageVisualPresetFrame(
                weights: displayedPresetWeights,
                composition: displayedComposition
            )
        }

        if requestedMood != observedVisualMood
            || requestedPalette != observedVisualPalette
            || requestedPointCloudChoice != observedPointCloudChoice
        {
            if requestedPointCloudChoice == .albumRelief,
               requestedPointCloudChoice != observedPointCloudChoice
            {
                camera.enterAlbumReliefView()
            }
            observedVisualMood = requestedMood
            observedVisualPalette = requestedPalette
            observedPointCloudChoice = requestedPointCloudChoice
            presetTransitionOrigin = displayedPresetWeights
            compositionTransitionOrigin = displayedComposition
            paletteTransitionOrigin = displayedPalette
            presetTransitionStartedAt = time
        }

        let targetFrame = resolvedFrame
        let targetWeights = targetFrame.weights
        let targetPalette = requestedPalette ?? automaticPalette

        guard let transitionStartedAt = presetTransitionStartedAt else {
            displayedPresetWeights = targetWeights
            displayedComposition = targetFrame.composition
            displayedPalette = targetPalette
            return StageVisualPresetFrame(
                weights: displayedPresetWeights,
                composition: displayedComposition
            )
        }

        let requestedTransitionDuration = Float(
            max(visualDirections.transitionDuration, 0.05)
        )
        let linearProgress = min(
            max((time - transitionStartedAt) / requestedTransitionDuration, 0),
            1
        )
        let smoothProgress = linearProgress * linearProgress
            * (3 - 2 * linearProgress)
        displayedPresetWeights = presetTransitionOrigin
            + (targetWeights - presetTransitionOrigin) * smoothProgress
        displayedComposition = compositionTransitionOrigin
            + (targetFrame.composition - compositionTransitionOrigin)
                * smoothProgress
        displayedPalette = StageVisualPalette.interpolated(
            from: paletteTransitionOrigin,
            to: targetPalette,
            progress: smoothProgress
        )
        if linearProgress >= 1 {
            presetTransitionStartedAt = nil
        }
        return StageVisualPresetFrame(
            weights: displayedPresetWeights,
            composition: displayedComposition
        )
    }

    private static func seconds(_ duration: Duration) -> Float {
        let components = duration.components
        return Float(
            Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        )
    }
}
