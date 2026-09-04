import Metal
import MetalKit
import MMDSceneKit
import QuartzCore
import SceneKit
import simd
import Testing
@testable import GMGNRadio

@Test
func oneShotMotionDeadlineFiresOnceAtItsDuration() {
    let url = URL(fileURLWithPath: "/tmp/backflip.vmd")
    var playback = PMXOneShotMotionPlayback.begin(
        url: url,
        duration: 1.5,
        currentTime: 4,
        repeats: false
    )

    #expect(playback?.finishIfNeeded(at: 5.49) == nil)
    #expect(playback?.finishIfNeeded(at: 5.5) == url)
    #expect(playback?.finishIfNeeded(at: 8) == nil)
    #expect(
        PMXOneShotMotionPlayback.begin(
            url: url,
            duration: 1.5,
            currentTime: 4,
            repeats: true
        ) == nil
    )
}

@Suite
@MainActor
struct PMXStageAvatarRendererTests {
    @Test
    func livingPodFactoryBuildsEveryReadableActivityZone() {
        let pod = LivingPodScene.makeRoomNode()

        #expect(pod.name == "gmgn-living-pod-room")
        #expect(pod.childNode(withName: "sleep-pod", recursively: true) != nil)
        #expect(pod.childNode(withName: "workbench-console", recursively: true) != nil)
        #expect(pod.childNode(withName: "jukebox", recursively: true) != nil)
        #expect(pod.childNode(withName: "coffee-machine", recursively: true) != nil)
        #expect(pod.childNode(withName: "viewport", recursively: true) != nil)
        #expect(pod.childNode(withName: "airlock", recursively: true) != nil)
    }

    @Test
    func livingPodOnlyReplacesTheWorldInFullStage() {
        #expect(LivingPodScene.isLocalWorld(LivingPodScene.worldID))
        #expect(!LivingPodScene.isLocalWorld("world-labs-example-warm-kitchen"))
        #expect(
            LivingPodScene.shouldDisplay(
                worldID: LivingPodScene.worldID,
                drawsWorld: true
            )
        )
        #expect(
            !LivingPodScene.shouldDisplay(
                worldID: LivingPodScene.worldID,
                drawsWorld: false
            )
        )
    }

    @Test
    func coffeeMachineFactoryBuildsAVisibleCountertopProp() throws {
        let machine = PMXWorldPropFactory.coffeeMachine()

        #expect(machine.name == "gmgn-coffee-machine")
        #expect(machine.childNode(withName: "body", recursively: true) != nil)
        #expect(machine.childNode(withName: "brew-button", recursively: true) != nil)
        #expect(machine.childNode(withName: "nozzle", recursively: true) != nil)
        #expect(machine.childNode(withName: "drip-tray", recursively: true) != nil)
        #expect(machine.boundingBox.max.y - machine.boundingBox.min.y >= 0.25)
    }

    @Test
    func coffeeMachineIsHiddenUntilTheFullStageRequestsIt() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = PMXStageAvatarRenderer(device: device)

        #expect(!renderer.isCoffeeMachineVisible)
        renderer.setCoffeeMachineVisible(true)
        #expect(renderer.isCoffeeMachineVisible)
        renderer.setCoffeeMachineVisible(false)
        #expect(!renderer.isCoffeeMachineVisible)
    }

    @Test
    func coffeeMachineSitsOnTheRightCounterAndFacesTheInteractionPoint() {
        let node = PMXWorldPropFactory.coffeeMachine()
        let machine = PMXWarmKitchenCoffeeMachine.scenePosition
        let interaction = PMXWarmKitchenCoffeeMachine.interactionPosition
        let scale = PMXWarmKitchenCoffeeMachine.sceneScale
        let horizontalDirection = simd_normalize(
            SIMD3<Float>(interaction.x - machine.x, 0, interaction.z - machine.z)
        )
        let avatarDirection = simd_normalize(
            SIMD3<Float>(machine.x - interaction.x, 0, machine.z - interaction.z)
        )
        let avatarForward = simd_act(
            simd_quatf(
                angle: PMXWarmKitchenCoffeeMachine.interactionYaw,
                axis: SIMD3<Float>(0, 1, 0)
            ),
            SIMD3<Float>(0, 0, 1)
        )

        #expect(machine == SIMD3<Float>(0.68, 0.5135225, -1.28))
        #expect(interaction == SIMD3<Float>(0.38, 0, -1.28))
        #expect(abs(scale - 0.6739059) < 0.0001)
        let machineBottom = machine.y + Float(node.boundingBox.min.y) * scale
        let surfaceDelta = machineBottom - PMXWarmKitchenCoffeeMachine.countertopSurfaceY
        #expect(abs(surfaceDelta) < 0.0001)
        #expect(
            simd_dot(
                PMXWarmKitchenCoffeeMachine.frontDirection,
                horizontalDirection
            ) > 0.999
        )
        #expect(simd_dot(avatarForward, avatarDirection) > 0.999)
    }

    @Test
    func coffeeMachineOnlyAppearsInTheWarmKitchenWorldView() {
        #expect(
            PMXWarmKitchenCoffeeMachine.shouldDisplay(
                worldID: "world-labs-example-warm-kitchen",
                drawsWorld: true
            )
        )
        #expect(
            !PMXWarmKitchenCoffeeMachine.shouldDisplay(
                worldID: "world-labs-example-warm-kitchen",
                drawsWorld: false
            )
        )
        #expect(
            !PMXWarmKitchenCoffeeMachine.shouldDisplay(
                worldID: "another-world",
                drawsWorld: true
            )
        )
    }

    @Test
    func coffeeCupFactoryBuildsASmallHandheldProp() {
        let cup = PMXWorldPropFactory.coffeeCup()

        #expect(cup.name == PMXWarmKitchenCoffeeCup.nodeName)
        #expect(cup.childNodes.contains { $0.geometry != nil })
        let bounds = cup.boundingBox
        let height = bounds.max.y - bounds.min.y
        #expect(height > 0)
        #expect(height < 0.2)
    }

    @Test
    func coffeeCupOnlyRidesTheGeneratedSipMotion() {
        #expect(
            PMXWarmKitchenCoffeeCup.shouldDisplay(
                motionID: PMXWarmKitchenCoffeeCup.motionID
            )
        )
        #expect(
            !PMXWarmKitchenCoffeeCup.shouldDisplay(
                motionID: "gmgn.motion.bones.coffee-button-pmx"
            )
        )
        #expect(!PMXWarmKitchenCoffeeCup.shouldDisplay(motionID: nil))
    }

    @Test
    func coffeeCupAttachesToTheAnimatedLeftWrist() {
        let standard = SCNNode()
        let standardWrist = SCNNode()
        standardWrist.name = "左手首"
        standard.addChildNode(standardWrist)
        #expect(
            PMXWarmKitchenCoffeeCup.wristBone(in: standard) === standardWrist
        )

        let raw2B = SCNNode()
        let raw2BWrist = SCNNode()
        raw2BWrist.name = "bone013"
        raw2B.addChildNode(raw2BWrist)
        #expect(
            PMXWarmKitchenCoffeeCup.wristBone(in: raw2B) === raw2BWrist
        )

        let missing = SCNNode()
        let rightWrist = SCNNode()
        rightWrist.name = "右手首"
        missing.addChildNode(rightWrist)
        #expect(PMXWarmKitchenCoffeeCup.wristBone(in: missing) == nil)
    }

    @Test
    func coffeeCupStartsHiddenAndFollowsTheSipVisibilityRequest() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = PMXStageAvatarRenderer(device: device)

        #expect(!renderer.isCoffeeCupVisible)
        renderer.setCoffeeCupVisible(true)
        #expect(renderer.isCoffeeCupVisible)
        renderer.setCoffeeCupVisible(false)
        #expect(!renderer.isCoffeeCupVisible)
    }

    @Test
    func renderTimelineStartsAtZeroAndClampsLargeFrameGaps() {
        var timeline = PMXRenderTimeline(maximumStep: 1.0 / 20.0)

        #expect(timeline.advance(to: 800_000_000) == 0)
        #expect(abs(timeline.advance(to: 800_000_000.016) - 0.016) < 0.0001)
        #expect(abs(timeline.advance(to: 800_000_100) - 0.066) < 0.0001)
        #expect(abs(timeline.advance(to: 800_000_099) - 0.066) < 0.0001)
    }

    @Test
    func replacingAMotionRestartsTheLocalAnimationClock() {
        var timeline = PMXRenderTimeline(maximumStep: 1.0 / 20.0)
        _ = timeline.advance(to: 100)
        _ = timeline.advance(to: 101)
        #expect(timeline.elapsed > 0)

        timeline.restartAnimationClock()

        #expect(timeline.elapsed == 0)
        #expect(timeline.advance(to: 101.016) == 0)
        #expect(abs(timeline.advance(to: 101.032) - 0.016) < 0.0001)
    }

    @Test
    func motionProbeReportsObservedBoneRotationAfterPlaybackAdvances() {
        var probe = PMXMotionPlaybackProbe(
            boneName: "左ひざ",
            reportAfter: 0.3
        )
        let rest = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
        let bent = simd_quatf(angle: 0.6, axis: SIMD3<Float>(1, 0, 0))

        #expect(probe.record(time: 0, orientation: rest) == nil)
        #expect(probe.record(time: 0.15, orientation: bent) == nil)
        let report = probe.record(time: 0.31, orientation: rest)

        #expect(report != nil)
        #expect((report?.maximumRotationDelta ?? 0) > 0.04)
        #expect(probe.record(time: 0.6, orientation: bent) == nil)
    }

    @Test
    func rendererAttachesAndDetachesTheModelPhysicsConstraints() {
        let scene = SCNScene()
        let model = MMDNode()
        let first = SCNNode()
        let second = SCNNode()
        first.physicsBody = .dynamic()
        second.physicsBody = .kinematic()
        model.addChildNode(first)
        model.addChildNode(second)
        let joint = SCNPhysicsBallSocketJoint(
            bodyA: first.physicsBody!,
            anchorA: SCNVector3Zero,
            bodyB: second.physicsBody!,
            anchorB: SCNVector3Zero
        )
        model.joints = [joint]
        scene.rootNode.addChildNode(model)

        PMXStageAvatarRenderer.attachPhysicsBehaviors(
            of: model,
            to: scene
        )
        #expect(scene.physicsWorld.allBehaviors.count == 1)

        PMXStageAvatarRenderer.detachPhysicsBehaviors(
            of: model,
            from: scene
        )
        #expect(scene.physicsWorld.allBehaviors.isEmpty)
    }

    @Test
    func acceptsPMXWithVMDOrNoMotion() {
        let modelURL = URL(fileURLWithPath: "/tmp/miku.PMX")

        #expect(
            PMXStageAvatarRenderer.compatibility(
                modelURL: modelURL,
                motionURL: nil
            ) == .compatible
        )
        #expect(
            PMXStageAvatarRenderer.compatibility(
                modelURL: modelURL,
                motionURL: URL(fileURLWithPath: "/tmp/dance.vMd")
            ) == .compatible
        )
    }

    @Test
    func rejectsUnsupportedModelAndMotionCombinationsWithLocalReason() {
        let vrmModel = URL(fileURLWithPath: "/tmp/avatar.vrm")
        let pmxModel = URL(fileURLWithPath: "/tmp/avatar.pmx")
        let vrmaMotion = URL(fileURLWithPath: "/tmp/wave.vrma")

        #expect(
            PMXStageAvatarRenderer.compatibility(
                modelURL: vrmModel,
                motionURL: nil
            ) == .incompatible(reason: "PMX 渲染器只能加载 .pmx 模型。")
        )
        #expect(
            PMXStageAvatarRenderer.compatibility(
                modelURL: pmxModel,
                motionURL: vrmaMotion
            ) == .incompatible(reason: "PMX 模型目前只支持 .vmd 动作。")
        )
    }

    @Test
    func sharedStagePassLoadsAndStoresExistingColorAndDepth() {
        let descriptor = MTLRenderPassDescriptor()

        PMXStageAvatarRenderer.configureSharedStagePass(descriptor)

        #expect(descriptor.colorAttachments[0].loadAction == .load)
        #expect(descriptor.colorAttachments[0].storeAction == .store)
        #expect(descriptor.depthAttachment.loadAction == .load)
        #expect(descriptor.depthAttachment.storeAction == .store)
    }

    @Test
    func currentSceneKitMaterialsReplaceLegacyShadersWithTheirTextures() throws {
        let root = SCNNode()
        let geometry = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
        let material = SCNMaterial()
        let texture = NSImage(size: NSSize(width: 2, height: 2))
        let authoredTint = NSColor(
            calibratedRed: 0.12,
            green: 0.14,
            blue: 0.16,
            alpha: 1
        )
        material.diffuse.contents = authoredTint
        material.emission.contents = NSColor(
            calibratedWhite: 0.4,
            alpha: 1
        )
        material.multiply.contents = texture
        material.shaderModifiers = [
            .fragment: "#pragma body\n_output.color = float4(1.0);",
        ]
        geometry.materials = [material]
        root.geometry = geometry

        PMXMaterialCompatibility.prepareForCurrentSceneKit(in: root)

        #expect(material.shaderModifiers == nil)
        #expect(material.diffuse.contents as? NSImage === texture)
        #expect(material.multiply.contents as? NSColor == authoredTint)
        #expect(material.lightingModel == .blinn)
        #expect(material.diffuse.intensity == 1)
        #expect(material.specular.intensity < 0.25)
        #expect(material.emission.intensity == 0)
    }

    @Test
    func hairMaterialsPreserveAlphaInsteadOfRenderingTextureCards() throws {
        let root = SCNNode()
        let geometry = SCNBox(
            width: 1,
            height: 1,
            length: 1,
            chamferRadius: 0
        )
        let material = SCNMaterial()
        material.name = "Hair Out"
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 2,
                pixelsHigh: 2,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        bitmap.setColor(
            NSColor(deviceRed: 0.4, green: 0.5, blue: 0.6, alpha: 0),
            atX: 0,
            y: 0
        )
        let texture = NSImage(size: NSSize(width: 2, height: 2))
        texture.addRepresentation(bitmap)
        material.multiply.contents = texture
        geometry.materials = [material]
        root.geometry = geometry

        PMXMaterialCompatibility.prepareForCurrentSceneKit(in: root)

        let prepared = try #require(material.diffuse.contents as? NSImage)
        let tiff = try #require(prepared.tiffRepresentation)
        let representation = try #require(NSBitmapImageRep(data: tiff))
        let pixel = try #require(representation.colorAt(x: 0, y: 0))
        #expect(prepared === texture)
        #expect(pixel.alphaComponent == 0)
        #expect(material.transparencyMode == .aOne)
        #expect(material.blendMode == .alpha)
        #expect(material.isDoubleSided)
    }

    @Test
    func raw2BCompatibilityDropsMalformedMorphTargetsBeforeRendering() {
        let model = MMDNode()
        model.addChildNode(SCNNode())
        model.childNodes[0].name = "bone4094"
        let geometryNode = SCNNode()
        let geometry = SCNBox(
            width: 1,
            height: 1,
            length: 1,
            chamferRadius: 0
        )
        let morpher = SCNMorpher()
        morpher.targets = [geometry]
        geometryNode.geometry = geometry
        geometryNode.morpher = morpher
        model.addChildNode(geometryNode)

        PMXMaterialCompatibility.prepareForCurrentSceneKit(in: model)

        #expect(geometryNode.morpher == nil)
    }

    @Test
    func standardPMXCompatibilityAlsoDropsUnsafeMorphTargetsAndTheirMotionTracks() {
        let model = MMDNode()
        for name in ["センター", "上半身", "左腕", "右腕", "左足", "右足"] {
            let bone = SCNNode()
            bone.name = name
            model.addChildNode(bone)
        }
        let geometryNode = SCNNode()
        let geometry = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
        let morpher = SCNMorpher()
        morpher.targets = [geometry]
        geometryNode.geometry = geometry
        geometryNode.morpher = morpher
        model.geometryMorpher = morpher
        model.addChildNode(geometryNode)

        PMXMaterialCompatibility.prepareForCurrentSceneKit(in: model)

        #expect(geometryNode.morpher == nil)
        #expect(model.geometryMorpher == nil)

        let boneTrack = CAKeyframeAnimation(keyPath: "/左腕.transform.quaternion")
        let morphTrack = CAKeyframeAnimation(keyPath: "morpher.weights.笑い")
        let group = CAAnimationGroup()
        group.animations = [boneTrack, morphTrack]
        let safe = PMXStageAvatarRenderer.motionByRemovingMorphTracks(from: group)
        let paths = safe.animations?.compactMap { ($0 as? CAKeyframeAnimation)?.keyPath }
        #expect(paths == ["/左腕.transform.quaternion"])
    }

    @Test
    func standardMMDSkeletonNeverUsesTheRaw2BCompatibilityPath() {
        let model = MMDNode()
        for name in [
            "全ての親",
            "センター",
            "上半身",
            "左腕",
            "右腕",
            "左足",
            "右足",
            "bone4094",
        ] {
            let bone = SCNNode()
            bone.name = name
            model.addChildNode(bone)
        }

        #expect(!PMXMaterialCompatibility.isRaw2BModel(model))
    }

    @Test
    func anonymousRigUsesRaw2BCompatibilityWhenStandardMMDBonesAreAbsent() {
        let model = MMDNode()
        for name in ["bone4094", "bone000", "bone007", "bone011"] {
            let bone = SCNNode()
            bone.name = name
            model.addChildNode(bone)
        }

        #expect(PMXMaterialCompatibility.isRaw2BModel(model))
    }

    @Test
    func raw2BNaturalIdlePreservesTheAuthoredSkeleton() {
        let model = MMDNode()
        for name in ["bone4094", "bone002", "bone005"] {
            let node = SCNNode()
            node.name = name
            model.addChildNode(node)
        }
        for (shoulderName, armName, elbowName, elbowPosition) in [
            ("bone006", "bone007", "bone008", SIMD3<Float>(-16.597, -13.9265, 3.8202)),
            ("bone010", "bone011", "bone012", SIMD3<Float>(16.597, -13.9265, 3.8202)),
        ] {
            let shoulder = SCNNode()
            shoulder.name = shoulderName
            let arm = SCNNode()
            arm.name = armName
            let elbow = SCNNode()
            elbow.name = elbowName
            elbow.simdPosition = elbowPosition
            arm.addChildNode(elbow)
            shoulder.addChildNode(arm)
            model.addChildNode(shoulder)
        }

        let idle = PMXStageAvatarRenderer.naturalIdleMotion(for: model)
        let keyPaths = Set(
            (idle.animations ?? [])
                .compactMap { ($0 as? CAKeyframeAnimation)?.keyPath }
        )

        #expect(keyPaths.isEmpty)
    }

    @Test
    func raw2BMotionDropsMorphTracksWhenTheSourceHasNoSafeMorpher() {
        let model = MMDNode()
        for name in ["bone4094", "bone007"] {
            let bone = SCNNode()
            bone.name = name
            model.addChildNode(bone)
        }
        let arm = CAKeyframeAnimation(
            keyPath: "/左腕.transform.quaternion"
        )
        arm.values = [NSValue(scnVector4: SCNVector4(0, 0, 0, 1))]
        arm.keyTimes = [0]
        let morph = CAKeyframeAnimation(keyPath: "morpher.weights.笑い")
        morph.values = [0]
        morph.keyTimes = [0]
        let motion = CAAnimationGroup()
        motion.animations = [arm, morph]
        motion.duration = 1

        PMXStageAvatarRenderer.attachMotion(
            motion,
            to: model,
            key: "raw-2b",
            rootMotionEnabled: false
        )

        #expect(model.animationKeys.contains("raw-2b"))
    }

    @Test
    func raw2BPreparedMotionPreservesAllAuthoredCenterTranslation() throws {
        let model = MMDNode()
        for name in ["bone4094", "bone000"] {
            let bone = SCNNode()
            bone.name = name
            model.addChildNode(bone)
        }
        let centerX = CAKeyframeAnimation(
            keyPath: "/センター.transform.translation.x"
        )
        centerX.values = [Float(0), Float(1.2)]
        centerX.keyTimes = [0, 1]
        let centerY = CAKeyframeAnimation(
            keyPath: "/センター.transform.translation.y"
        )
        centerY.values = [Float(0), Float(2.4)]
        centerY.keyTimes = [0, 1]
        let centerZ = CAKeyframeAnimation(
            keyPath: "/センター.transform.translation.z"
        )
        centerZ.values = [Float(0), Float(-0.8)]
        centerZ.keyTimes = [0, 1]
        let motion = CAAnimationGroup()
        motion.animations = [centerX, centerY, centerZ]
        motion.duration = 1

        let prepared = PMXStageAvatarRenderer.preparedMotion(
            motion,
            for: model,
            rootMotionEnabled: false
        )
        let keyPaths = try #require(prepared.animations).compactMap {
            ($0 as? CAKeyframeAnimation)?.keyPath
        }

        #expect(keyPaths.contains("/bone000.transform.translation.x"))
        #expect(keyPaths.contains("/bone000.transform.translation.y"))
        #expect(keyPaths.contains("/bone000.transform.translation.z"))
    }

    @Test
    func raw2BInPlaceLocomotionDropsHorizontalRootTravelButKeepsVerticalBounce() throws {
        let model = MMDNode()
        for name in ["bone4094", "bone000"] {
            let bone = SCNNode()
            bone.name = name
            model.addChildNode(bone)
        }
        let rootX = CAKeyframeAnimation(
            keyPath: "/全ての親.transform.translation.x"
        )
        let centerX = CAKeyframeAnimation(
            keyPath: "/センター.transform.translation.x"
        )
        let centerY = CAKeyframeAnimation(
            keyPath: "/センター.transform.translation.y"
        )
        let centerZ = CAKeyframeAnimation(
            keyPath: "/センター.transform.translation.z"
        )
        let leftLeg = CAKeyframeAnimation(
            keyPath: "/左足.transform.quaternion"
        )
        let motion = CAAnimationGroup()
        motion.animations = [rootX, centerX, centerY, centerZ, leftLeg]

        let prepared = PMXStageAvatarRenderer.preparedMotion(
            motion,
            for: model,
            rootMotionEnabled: false,
            inPlace: true
        )
        let keyPaths = try #require(prepared.animations).compactMap {
            ($0 as? CAKeyframeAnimation)?.keyPath
        }

        #expect(keyPaths.contains("/bone000.transform.translation.y"))
        #expect(keyPaths.contains("/bone003.transform.quaternion"))
        #expect(!keyPaths.contains("/bone4094.transform.translation.x"))
        #expect(!keyPaths.contains("/bone000.transform.translation.x"))
        #expect(!keyPaths.contains("/bone000.transform.translation.z"))
    }

    @Test
    func raw2BPreparedMotionComposesCenterAndGrooveOnSeparateNodes() throws {
        let model = MMDNode()
        let root = SCNNode()
        root.name = "bone4094"
        model.addChildNode(root)
        let center = SCNNode()
        center.name = "bone000"
        root.addChildNode(center)

        let centerY = CAKeyframeAnimation(
            keyPath: "/センター.transform.translation.y"
        )
        centerY.values = [Float(-0.8)]
        centerY.keyTimes = [0]
        let grooveY = CAKeyframeAnimation(
            keyPath: "/グルーブ.transform.translation.y"
        )
        grooveY.values = [Float(0)]
        grooveY.keyTimes = [0]
        let motion = CAAnimationGroup()
        motion.animations = [centerY, grooveY]
        motion.duration = 1

        let prepared = PMXStageAvatarRenderer.preparedMotion(
            motion,
            for: model,
            rootMotionEnabled: false
        )
        let keyPaths = try #require(prepared.animations).compactMap {
            ($0 as? CAKeyframeAnimation)?.keyPath
        }

        #expect(keyPaths.contains("/bone000.transform.translation.y"))
        #expect(
            keyPaths.contains(
                "/gmgn_raw2b_groove.transform.translation.y"
            )
        )
        #expect(center.parent?.name == "gmgn_raw2b_groove")
    }

    @Test
    func raw2BPreparedMotionComposesRotationWithTargetRestPose() throws {
        let model = MMDNode()
        let marker = SCNNode()
        marker.name = "bone4094"
        model.addChildNode(marker)
        let arm = SCNNode()
        arm.name = "bone011"
        arm.simdOrientation = simd_quatf(
            angle: .pi / 5,
            axis: SIMD3<Float>(0, 0, 1)
        )
        model.addChildNode(arm)
        let elbow = SCNNode()
        elbow.name = "bone012"
        elbow.simdPosition = SIMD3<Float>(2, -1, 2)
        arm.addChildNode(elbow)

        let sourceDelta = simd_quatf(
            angle: -.pi / 4,
            axis: simd_normalize(SIMD3<Float>(0.2, 0.8, -0.4))
        )

        let source = CAKeyframeAnimation(
            keyPath: "/左腕.transform.quaternion"
        )
        source.values = [
            NSValue(
                scnVector4: SCNVector4(
                    sourceDelta.vector.x,
                    sourceDelta.vector.y,
                    sourceDelta.vector.z,
                    sourceDelta.vector.w
                )
            ),
        ]
        source.keyTimes = [0]
        let motion = CAAnimationGroup()
        motion.animations = [source]
        motion.duration = 1

        let prepared = PMXStageAvatarRenderer.preparedMotion(
            motion,
            for: model,
            rootMotionEnabled: false
        )
        let track = try #require(
            prepared.animations?
                .compactMap { $0 as? CAKeyframeAnimation }
                .first { $0.keyPath == "/bone011.transform.quaternion" }
        )
        let value = try #require(track.values?.first as? NSValue)
            .scnVector4Value
        let expected = simd_normalize(arm.simdOrientation * sourceDelta)

        #expect(abs(Float(value.x) - expected.vector.x) < 0.0001)
        #expect(abs(Float(value.y) - expected.vector.y) < 0.0001)
        #expect(abs(Float(value.z) - expected.vector.z) < 0.0001)
        #expect(abs(Float(value.w) - expected.vector.w) < 0.0001)
    }

    @Test
    func generatedHumanoidMotionRetargetsUpperArmToStandardPMXBindDirection() throws {
        let model = MMDNode()
        let arm = SCNNode()
        arm.name = "左腕"
        model.addChildNode(arm)
        let elbow = SCNNode()
        elbow.name = "左ひじ"
        elbow.simdPosition = SIMD3<Float>(2, -1, 2)
        arm.addChildNode(elbow)

        let sourceDelta = simd_quatf(
            angle: -.pi / 3,
            axis: SIMD3<Float>(0, 0, 1)
        )
        let source = CAKeyframeAnimation(
            keyPath: "/左腕.transform.quaternion"
        )
        source.values = [NSValue(scnVector4: SCNVector4(
            sourceDelta.vector.x,
            sourceDelta.vector.y,
            sourceDelta.vector.z,
            sourceDelta.vector.w
        ))]
        source.keyTimes = [0]
        let motion = CAAnimationGroup()
        motion.animations = [source]
        motion.duration = 1

        let prepared = PMXStageAvatarRenderer.preparedMotion(
            motion,
            for: model,
            rootMotionEnabled: false,
            retargetsGeneratedHumanoidMotion: true
        )
        let track = try #require(
            prepared.animations?
                .compactMap { $0 as? CAKeyframeAnimation }
                .first { $0.keyPath == "/左腕.transform.quaternion" }
        )
        let value = try #require(track.values?.first as? NSValue)
            .scnVector4Value
        let actual = simd_quatf(vector: SIMD4<Float>(
            Float(value.x), Float(value.y), Float(value.z), Float(value.w)
        ))
        let sourceToTargetBasis = simd_quatf(
            from: SIMD3<Float>(1, 0, 0),
            to: simd_normalize(elbow.simdPosition)
        )
        let expected = PMXBoneRotationRetargeting.hierarchyAwareOrientation(
            sourceDelta: sourceDelta,
            parentSourceToTargetBasis: simd_quatf(
                angle: 0,
                axis: SIMD3<Float>(0, 1, 0)
            ),
            sourceToTargetBasis: sourceToTargetBasis,
            targetRestOrientation: arm.simdOrientation
        )

        #expect(abs(simd_dot(actual.vector, expected.vector)) > 0.9999)
        #expect(abs(simd_dot(actual.vector, sourceDelta.vector)) < 0.99)
    }

    @Test
    func generatedHumanoidRetargetingDoesNotApplyParentBindCorrectionTwice() {
        let sourceDelta = simd_quatf(
            angle: -.pi / 3,
            axis: SIMD3<Float>(0, 0, 1)
        )
        let parentBasis = simd_quatf(
            angle: -.pi / 10,
            axis: SIMD3<Float>(0, 0, 1)
        )
        let jointBasis = simd_quatf(
            angle: -.pi / 4,
            axis: simd_normalize(SIMD3<Float>(0, 1, 1))
        )
        let targetRest = simd_quatf(
            angle: .pi / 12,
            axis: SIMD3<Float>(1, 0, 0)
        )

        let actual = PMXBoneRotationRetargeting.hierarchyAwareOrientation(
            sourceDelta: sourceDelta,
            parentSourceToTargetBasis: parentBasis,
            sourceToTargetBasis: jointBasis,
            targetRestOrientation: targetRest
        )
        let expected = simd_normalize(
            parentBasis * sourceDelta * jointBasis.inverse * targetRest
        )
        let independentlyConjugated = simd_normalize(
            jointBasis * sourceDelta * jointBasis.inverse * targetRest
        )

        #expect(abs(simd_dot(actual.vector, expected.vector)) > 0.9999)
        #expect(abs(simd_dot(actual.vector, independentlyConjugated.vector)) < 0.99)
    }

    @Test
    func raw2BRetargetingMapsFingersAndArmTwistThroughFullFrames() throws {
        let model = MMDNode()
        let marker = SCNNode()
        marker.name = "bone4094"
        model.addChildNode(marker)
        let expectedTargets: [String: String] = [
            "左腕捩": "bone2561", "左手捩": "bone2592",
            "右腕捩": "bone2560", "右手捩": "bone2576",
            "左親指０": "bone512", "左親指１": "bone513",
            "左親指２": "bone514", "左人指１": "bone515",
            "左人指２": "bone516", "左人指３": "bone517",
            "左中指１": "bone519", "左中指２": "bone520",
            "左中指３": "bone521", "左薬指１": "bone523",
            "左薬指２": "bone524", "左薬指３": "bone525",
            "左小指１": "bone527", "左小指２": "bone528",
            "左小指３": "bone529", "右親指０": "bone256",
            "右親指１": "bone257", "右親指２": "bone258",
            "右人指１": "bone259", "右人指２": "bone260",
            "右人指３": "bone261", "右中指１": "bone263",
            "右中指２": "bone264", "右中指３": "bone265",
            "右薬指１": "bone267", "右薬指２": "bone268",
            "右薬指３": "bone269", "右小指１": "bone271",
            "右小指２": "bone272", "右小指３": "bone273",
        ]
        for targetName in Set(expectedTargets.values) {
            let bone = SCNNode()
            bone.name = targetName
            model.addChildNode(bone)
        }
        let motion = CAAnimationGroup()
        motion.animations = expectedTargets.keys.map { sourceName in
            let track = CAKeyframeAnimation(
                keyPath: "/\(sourceName).transform.quaternion"
            )
            track.values = [NSValue(scnVector4: SCNVector4(0, 0, 0, 1))]
            track.keyTimes = [0]
            return track
        }
        motion.duration = 1

        let prepared = PMXStageAvatarRenderer.preparedMotion(
            motion,
            for: model,
            rootMotionEnabled: false
        )
        let keyPaths = Set(
            try #require(prepared.animations).compactMap {
                ($0 as? CAKeyframeAnimation)?.keyPath
            }
        )

        for targetName in expectedTargets.values {
            #expect(keyPaths.contains("/\(targetName).transform.quaternion"))
        }
        #expect(keyPaths.count == expectedTargets.count)
    }

    @Test
    func raw2BFingerMotionUsesTheAuthoredDeltaOnTheOriginalBindPose() throws {
        let model = MMDNode()
        let marker = SCNNode()
        marker.name = "bone4094"
        model.addChildNode(marker)

        let wrist = SCNNode()
        wrist.name = "bone013"
        model.addChildNode(wrist)
        let fingerRoots: [(String, SIMD3<Float>)] = [
            ("bone515", SIMD3<Float>(1, -1, 1)),
            ("bone519", SIMD3<Float>(0.5, -1, 1)),
            ("bone523", SIMD3<Float>(0, -1, 1)),
            ("bone527", SIMD3<Float>(-1, -1, 1)),
        ]
        for (name, position) in fingerRoots {
            let node = SCNNode()
            node.name = name
            node.simdPosition = position
            wrist.addChildNode(node)
        }
        let index = try #require(
            model.childNode(withName: "bone515", recursively: true)
        )
        let indexChild = SCNNode()
        indexChild.name = "bone516"
        indexChild.simdPosition = SIMD3<Float>(1.9558, -1.9982, 2.3140)
        index.addChildNode(indexChild)

        let sourceDelta = simd_quatf(
            angle: -.pi / 3,
            axis: SIMD3<Float>(0, 0, 1)
        )
        let source = CAKeyframeAnimation(
            keyPath: "/左人指１.transform.quaternion"
        )
        source.values = [
            NSValue(
                scnVector4: SCNVector4(
                    sourceDelta.vector.x,
                    sourceDelta.vector.y,
                    sourceDelta.vector.z,
                    sourceDelta.vector.w
                )
            ),
        ]
        source.keyTimes = [0]
        let motion = CAAnimationGroup()
        motion.animations = [source]
        motion.duration = 1

        let prepared = PMXStageAvatarRenderer.preparedMotion(
            motion,
            for: model,
            rootMotionEnabled: false
        )
        let track = try #require(
            prepared.animations?
                .compactMap { $0 as? CAKeyframeAnimation }
                .first { $0.keyPath == "/bone515.transform.quaternion" }
        )
        let value = try #require(track.values?.first as? NSValue)
            .scnVector4Value
        let actual = simd_quatf(
            vector: SIMD4<Float>(
                Float(value.x), Float(value.y), Float(value.z), Float(value.w)
            )
        )
        let expected = simd_normalize(index.simdOrientation * sourceDelta)

        #expect(
            abs(simd_dot(
                simd_normalize(actual.vector),
                simd_normalize(expected.vector)
            )) > 0.9999
        )
    }

    @Test
    func raw2BGeneratedAnimationPathsDoNotContainSceneKitDelimitersInNodeNames() throws {
        let model = MMDNode()
        let root = SCNNode()
        root.name = "bone4094"
        model.addChildNode(root)
        let center = SCNNode()
        center.name = "bone000"
        root.addChildNode(center)
        let source = CAKeyframeAnimation(
            keyPath: "/グルーブ.transform.translation.y"
        )
        source.values = [Float(0)]
        source.keyTimes = [0]
        let motion = CAAnimationGroup()
        motion.animations = [source]
        motion.duration = 1

        let prepared = PMXStageAvatarRenderer.preparedMotion(
            motion,
            for: model,
            rootMotionEnabled: false
        )
        let keyPath = try #require(
            prepared.animations?
                .compactMap { ($0 as? CAKeyframeAnimation)?.keyPath }
                .first
        )
        let nodeName = try #require(
            keyPath.dropFirst().split(separator: ".", maxSplits: 1).first
        )

        #expect(!nodeName.contains("."))
        #expect(nodeName == "gmgn_raw2b_groove")
    }

    @Test
    func raw2BSingleFrameTracksAlwaysUseAFiniteKeyTime() throws {
        let model = MMDNode()
        for name in ["bone4094", "bone2561"] {
            let bone = SCNNode()
            bone.name = name
            model.addChildNode(bone)
        }
        let source = CAKeyframeAnimation(
            keyPath: "/左腕捩.transform.quaternion"
        )
        source.values = [NSValue(scnVector4: SCNVector4(0, 0, 0, 1))]
        source.keyTimes = [NSNumber(value: Double.nan)]
        let motion = CAAnimationGroup()
        motion.animations = [source]
        motion.duration = 1

        let prepared = PMXStageAvatarRenderer.preparedMotion(
            motion,
            for: model,
            rootMotionEnabled: false
        )
        let track = try #require(
            prepared.animations?.first as? CAKeyframeAnimation
        )
        let keyTime = try #require(track.keyTimes?.first)

        #expect(keyTime.doubleValue == 0)
        #expect(keyTime.doubleValue.isFinite)
    }

    @Test
    func raw2BIdentityLimbMotionPreservesTheModelsRestPose() throws {
        let model = MMDNode()
        let marker = SCNNode()
        marker.name = "bone4094"
        model.addChildNode(marker)
        let arm = SCNNode()
        arm.name = "bone011"
        model.addChildNode(arm)
        let elbow = SCNNode()
        elbow.name = "bone012"
        elbow.simdPosition = SIMD3<Float>(2, -1, 2)
        arm.addChildNode(elbow)

        let source = CAKeyframeAnimation(
            keyPath: "/左腕.transform.quaternion"
        )
        source.values = [NSValue(scnVector4: SCNVector4(0, 0, 0, 1))]
        source.keyTimes = [0]
        let motion = CAAnimationGroup()
        motion.animations = [source]
        motion.duration = 1

        let prepared = PMXStageAvatarRenderer.preparedMotion(
            motion,
            for: model,
            rootMotionEnabled: false
        )
        let track = try #require(
            prepared.animations?
                .compactMap { $0 as? CAKeyframeAnimation }
                .first { $0.keyPath == "/bone011.transform.quaternion" }
        )
        let value = try #require(track.values?.first as? NSValue)
            .scnVector4Value
        let rotation = simd_quatf(
            vector: SIMD4<Float>(
                Float(value.x), Float(value.y), Float(value.z), Float(value.w)
            )
        )
        #expect(
            abs(simd_dot(
                simd_normalize(rotation.vector),
                simd_normalize(arm.simdOrientation.vector)
            )) > 0.9999
        )
    }

    @Test
    func raw2BIdentityFingerMotionPreservesTheModelsRestPose() {
        let targetRest = simd_quatf(
            angle: 0.31,
            axis: simd_normalize(SIMD3<Float>(0.2, 0.8, -0.4))
        )

        let actual = PMXBoneRotationRetargeting.orientation(
            sourceDelta: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
            sourceRestDirection: SIMD3<Float>(0.3440, -0.2399, -0.0072),
            targetRestOrientation: targetRest,
            targetChildDirection: SIMD3<Float>(1.9558, -1.9982, -2.3140)
        )

        #expect(
            abs(simd_dot(
                simd_normalize(actual.vector),
                simd_normalize(targetRest.vector)
            )) > 0.9999
        )
    }

    @Test
    func soleProbeTracksTheAnimatedSoleInsteadOfTheToeBoneOrigin() throws {
        let model = MMDNode()
        let toe = SCNNode()
        toe.name = "toe"
        toe.simdPosition = SIMD3<Float>(0, 4, 0)
        model.addChildNode(toe)
        let probe = PMXSoleProbe(
            influences: [
                PMXSoleProbe.Influence(
                    bone: toe,
                    localPosition: SIMD3<Float>(0, -4, 2),
                    weight: 1
                ),
            ]
        )
        let restY = try #require(
            PMXSoleGrounding.referenceY(
                probes: [probe],
                in: model,
                usesPresentationTree: false
            )
        )
        toe.simdOrientation = simd_quatf(
            angle: .pi / 2,
            axis: SIMD3<Float>(1, 0, 0)
        )
        let animatedY = try #require(
            PMXSoleGrounding.referenceY(
                probes: [probe],
                in: model,
                usesPresentationTree: false
            )
        )

        #expect(abs(restY) < 0.0001)
        #expect(abs(animatedY - 2) < 0.0001)
        #expect(
            abs(
                PMXAnimatedGrounding.localOffsetY(
                    restFootReferenceY: restY,
                    animatedFootReferenceY: animatedY
                ) + 2
            ) < 0.0001
        )
    }

    @Test
    func soleGroundingRecognizesStandardAndRaw2BFootBones() {
        #expect(PMXSoleGrounding.isFootBoneName("左足首"))
        #expect(PMXSoleGrounding.isFootBoneName("右つま先D"))
        #expect(PMXSoleGrounding.isFootBoneName("bone017"))
        #expect(PMXSoleGrounding.isFootBoneName("LeftAnkle"))
        #expect(!PMXSoleGrounding.isFootBoneName("staff"))
        #expect(!PMXSoleGrounding.isFootBoneName("左腕"))
    }

    @Test
    func fullStageGroundingDoesNotFeedSoleMotionBackIntoRootLockedDance() {
        #expect(
            PMXFullStageGroundingPolicy.offset(
                rootMotionEnabled: false,
                animatedOffset: 12.5
            ) == 0
        )
        #expect(
            PMXFullStageGroundingPolicy.offset(
                rootMotionEnabled: true,
                animatedOffset: 12.5
            ) == 12.5
        )
    }

    @Test
    func geometrySourceReaderDecodesComponentsFromOneCachedBuffer() throws {
        let positions: [Float] = [
            1, 2, 3,
            4, 5, 6,
        ]
        let positionData = positions.withUnsafeBufferPointer { buffer in
            Data(
                bytes: buffer.baseAddress!,
                count: buffer.count * MemoryLayout<Float>.size
            )
        }
        let positionSource = SCNGeometrySource(
            data: positionData,
            semantic: .vertex,
            vectorCount: 2,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )
        let positionReader = PMXGeometrySourceReader(
            source: positionSource
        )

        #expect(
            positionReader.vector3(at: 1) == SIMD3<Float>(4, 5, 6)
        )

        let indices: [UInt16] = [2, 7, 11, 13]
        let indexData = indices.withUnsafeBufferPointer { buffer in
            Data(
                bytes: buffer.baseAddress!,
                count: buffer.count * MemoryLayout<UInt16>.size
            )
        }
        let indexSource = SCNGeometrySource(
            data: indexData,
            semantic: .boneIndices,
            vectorCount: 1,
            usesFloatComponents: false,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<UInt16>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<UInt16>.size * 4
        )
        let indexReader = PMXGeometrySourceReader(source: indexSource)

        #expect(indexReader.unsignedComponent(vector: 0, component: 2) == 11)
    }

    @Test
    func raw2BRetargetingKeepsMMDLeftAndRightOnTheMatchingModelSides() throws {
        let model = MMDNode()
        for name in ["bone4094", "bone007", "bone011"] {
            let bone = SCNNode()
            bone.name = name
            model.addChildNode(bone)
        }
        let leftArm = CAKeyframeAnimation(
            keyPath: "/左腕.transform.quaternion"
        )
        let leftRotation = simd_quatf(
            angle: 0.24,
            axis: SIMD3<Float>(1, 0, 0)
        )
        leftArm.values = [
            NSValue(
                scnVector4: SCNVector4(
                    leftRotation.vector.x,
                    leftRotation.vector.y,
                    leftRotation.vector.z,
                    leftRotation.vector.w
                )
            ),
        ]
        leftArm.keyTimes = [0]
        let rightArm = CAKeyframeAnimation(
            keyPath: "/右腕.transform.quaternion"
        )
        let rightRotation = simd_quatf(
            angle: -0.41,
            axis: SIMD3<Float>(0, 1, 0)
        )
        rightArm.values = [
            NSValue(
                scnVector4: SCNVector4(
                    rightRotation.vector.x,
                    rightRotation.vector.y,
                    rightRotation.vector.z,
                    rightRotation.vector.w
                )
            ),
        ]
        rightArm.keyTimes = [0]
        let motion = CAAnimationGroup()
        motion.animations = [leftArm, rightArm]
        motion.duration = 1

        let prepared = PMXStageAvatarRenderer.preparedMotion(
            motion,
            for: model,
            rootMotionEnabled: false
        )
        let tracks = try #require(prepared.animations).compactMap {
            $0 as? CAKeyframeAnimation
        }
        let targetLeft = try #require(
            tracks.first { $0.keyPath == "/bone011.transform.quaternion" }
        )
        let targetRight = try #require(
            tracks.first { $0.keyPath == "/bone007.transform.quaternion" }
        )
        let leftValue = try #require(targetLeft.values?.first as? NSValue)
            .scnVector4Value
        let rightValue = try #require(targetRight.values?.first as? NSValue)
            .scnVector4Value

        #expect(abs(Float(leftValue.x) - leftRotation.vector.x) < 0.0001)
        #expect(abs(Float(leftValue.w) - leftRotation.vector.w) < 0.0001)
        #expect(abs(Float(rightValue.y) - rightRotation.vector.y) < 0.0001)
        #expect(abs(Float(rightValue.w) - rightRotation.vector.w) < 0.0001)
    }

    @Test
    func raw2BRetargetingPreservesAuthoredBodyAndFootIKMotion() throws {
        let model = MMDNode()
        let root = SCNNode()
        root.name = "bone4094"
        model.addChildNode(root)
        let center = SCNNode()
        center.name = "bone000"
        root.addChildNode(center)

        let leftUpperLeg = SCNNode()
        leftUpperLeg.name = "bone019"
        center.addChildNode(leftUpperLeg)
        let leftKnee = SCNNode()
        leftKnee.name = "bone020"
        leftKnee.simdPosition = SIMD3<Float>(0, -4, 0)
        leftUpperLeg.addChildNode(leftKnee)
        let leftAnkle = SCNNode()
        leftAnkle.name = "bone021"
        leftAnkle.simdPosition = SIMD3<Float>(0, -4, 0)
        leftKnee.addChildNode(leftAnkle)

        let rightUpperLeg = SCNNode()
        rightUpperLeg.name = "bone015"
        center.addChildNode(rightUpperLeg)
        let rightKnee = SCNNode()
        rightKnee.name = "bone016"
        rightKnee.simdPosition = SIMD3<Float>(0, -4, 0)
        rightUpperLeg.addChildNode(rightKnee)
        let rightAnkle = SCNNode()
        rightAnkle.name = "bone017"
        rightAnkle.simdPosition = SIMD3<Float>(0, -4, 0)
        rightKnee.addChildNode(rightAnkle)

        let centerX = CAKeyframeAnimation(
            keyPath: "/センター.transform.translation.x"
        )
        centerX.values = [Float(1)]
        centerX.keyTimes = [0]
        let centerY = CAKeyframeAnimation(
            keyPath: "/センター.transform.translation.y"
        )
        centerY.values = [Float(-0.5)]
        centerY.keyTimes = [0]
        let leftFootX = CAKeyframeAnimation(
            keyPath: "/左足ＩＫ.transform.translation.x"
        )
        leftFootX.values = [Float(0.25)]
        leftFootX.keyTimes = [0]
        let rightFootY = CAKeyframeAnimation(
            keyPath: "/右足ＩＫ.transform.translation.y"
        )
        rightFootY.values = [Float(0.1)]
        rightFootY.keyTimes = [0]
        let motion = CAAnimationGroup()
        motion.animations = [centerX, centerY, leftFootX, rightFootY]
        motion.duration = 1

        let prepared = PMXStageAvatarRenderer.preparedMotion(
            motion,
            for: model,
            rootMotionEnabled: false
        )
        let keyPaths = try #require(prepared.animations).compactMap {
            ($0 as? CAKeyframeAnimation)?.keyPath
        }

        #expect(keyPaths.contains("/bone000.transform.translation.x"))
        #expect(keyPaths.contains("/bone000.transform.translation.y"))
        #expect(
            keyPaths.contains(
                "/gmgn_raw2b_left_foot_ik.transform.translation.x"
            )
        )
        #expect(
            keyPaths.contains(
                "/gmgn_raw2b_right_foot_ik.transform.translation.y"
            )
        )
        #expect(leftAnkle.constraints?.first is SCNIKConstraint)
        #expect(rightAnkle.constraints?.first is SCNIKConstraint)
    }

    @Test
    func cameraConfigurationTransfersViewAndProjectionMatrices() {
        let view = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(-2, -3, -4, 1)
        )
        let projection = simd_float4x4(
            SIMD4<Float>(2, 0, 0, 0),
            SIMD4<Float>(0, 3, 0, 0),
            SIMD4<Float>(0, 0, -1, -1),
            SIMD4<Float>(0, 0, -0.2, 0)
        )

        let configuration = PMXStageAvatarRenderer.cameraConfiguration(
            viewMatrix: view,
            projectionMatrix: projection
        )

        #expect(configuration.worldTransform.columns.3.x == 2)
        #expect(configuration.worldTransform.columns.3.y == 3)
        #expect(configuration.worldTransform.columns.3.z == 4)
        #expect(configuration.projectionTransform.columns.0.x == 2)
        #expect(configuration.projectionTransform.columns.1.y == 3)
        #expect(configuration.projectionTransform.columns.3.z == -0.2)
    }

    @Test
    func rootMotionIsDisabledByDefault() {
        #expect(PMXStageAvatarRenderer.Configuration.default.rootMotionEnabled == false)
    }

    @Test
    func failedMotionLoadKeepsTheCurrentMotion() {
        #expect(
            PMXStageAvatarRenderer.motionLoadFailurePolicy
                == .preserveCurrentMotion
        )
    }

    @Test
    func naturalIdleRelaxesStandardMMDArmsAndBreathes() throws {
        let model = MMDNode()
        for name in ["左腕", "右腕", "上半身", "頭"] {
            let bone = MMDNode()
            bone.name = name
            model.addChildNode(bone)
        }

        let idle = PMXStageAvatarRenderer.naturalIdleMotion(for: model)
        let tracks = try #require(idle.animations).compactMap {
            $0 as? CAKeyframeAnimation
        }
        let leftArm = try #require(
            tracks.first { $0.keyPath == "/左腕.transform.quaternion" }
        )
        let rightArm = try #require(
            tracks.first { $0.keyPath == "/右腕.transform.quaternion" }
        )
        let chest = try #require(
            tracks.first { $0.keyPath == "/上半身.transform.quaternion" }
        )
        let head = try #require(
            tracks.first { $0.keyPath == "/頭.transform.quaternion" }
        )
        let leftValue = try #require(leftArm.values?.first as? NSValue)
            .scnVector4Value
        let rightValue = try #require(rightArm.values?.first as? NSValue)
            .scnVector4Value

        #expect(leftValue.z < -0.2)
        #expect(rightValue.z > 0.2)
        #expect(chest.values?.count == 3)
        #expect(head.values?.count == 3)
        #expect(idle.duration > 3)
        #expect(idle.repeatCount == .infinity)
    }

    @Test
    func naturalIdleCanBeAttachedToAnMMDModel() {
        let model = MMDNode()
        let arm = MMDNode()
        arm.name = "左腕"
        model.addChildNode(arm)

        PMXStageAvatarRenderer.attachNaturalIdle(
            to: model,
            key: "test-natural-idle"
        )

        #expect(model.animationKeys.contains("test-natural-idle"))
    }

    @Test
    func modelWithoutVMDUsesNaturalIdleAndClearRestoresIt() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = PMXStageAvatarRenderer(device: device)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gmgn-pmx-idle-\(UUID().uuidString)")
        let modelURL = directory.appending(path: "empty.pmx")
        let motionURL = directory.appending(path: "empty.vmd")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.emptyPMXData().write(to: modelURL)
        try Self.emptyVMDData().write(to: motionURL)

        try await renderer.loadModel(
            from: modelURL,
            resourceRootURL: directory
        )
        #expect(renderer.isUsingNaturalIdle)

        try await renderer.loadMotion(from: motionURL)
        #expect(!renderer.isUsingNaturalIdle)

        renderer.clearMotion()
        #expect(renderer.isUsingNaturalIdle)
    }

    @Test
    func asyncModelLoadHonorsCancellationBeforeReading() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = PMXStageAvatarRenderer(device: device)
        let missingURL = URL(
            fileURLWithPath: "/tmp/cancelled-(UUID().uuidString).pmx"
        )
        let task = Task { @MainActor in
            try await renderer.loadModel(from: missingURL)
        }

        task.cancel()

        do {
            try await task.value
            Issue.record("已取消的 PMX 加载仍然继续执行")
        } catch is CancellationError {
            // Expected: cancellation wins before file IO or scene mutation.
        } catch {
            Issue.record("已取消的 PMX 加载返回了错误：\(error)")
        }
    }

    @Test
    func asyncMotionLoadStillRequiresAModel() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = PMXStageAvatarRenderer(device: device)

        do {
            try await renderer.loadMotion(
                from: URL(fileURLWithPath: "/tmp/missing.vmd")
            )
            Issue.record("没有模型时不应加载 VMD")
        } catch let error as PMXStageAvatarRenderer.LoadError {
            #expect(error == .modelNotLoaded)
        }
    }

    @Test
    func failedAsyncMotionLoadPreservesPreviousMotionURL() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = PMXStageAvatarRenderer(device: device)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gmgn-pmx-\(UUID().uuidString)")
        let modelURL = directory.appending(path: "empty.pmx")
        let validMotionURL = directory.appending(path: "idle.vmd")
        let invalidMotionURL = directory.appending(path: "broken.vmd")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.emptyPMXData().write(to: modelURL)
        try Self.emptyVMDData().write(to: validMotionURL)
        try Data("broken".utf8).write(to: invalidMotionURL)

        try await renderer.loadModel(
            from: modelURL,
            resourceRootURL: directory
        )
        try await renderer.loadMotion(from: validMotionURL)
        #expect(renderer.loadedMotionURL == validMotionURL)

        do {
            try await renderer.loadMotion(from: invalidMotionURL)
            Issue.record("损坏的 VMD 不应加载成功")
        } catch let error as PMXStageAvatarRenderer.LoadError {
            #expect(
                error == .invalidMotion(
                    fileName: invalidMotionURL.lastPathComponent
                )
            )
        }

        #expect(renderer.loadedMotionURL == validMotionURL)
    }

    @Test
    func modelMustStayInsideItsDeclaredResourceRoot() {
        let root = URL(fileURLWithPath: "/tmp/avatar-package")

        #expect(
            PMXStageAvatarRenderer.isModelURL(
                root.appending(path: "models/avatar.pmx"),
                containedIn: root
            )
        )
        #expect(
            !PMXStageAvatarRenderer.isModelURL(
                URL(fileURLWithPath: "/tmp/avatar-package-copy/avatar.pmx"),
                containedIn: root
            )
        )
        #expect(!PMXStageAvatarRenderer.isModelURL(root, containedIn: root))
    }

    @Test
    func rendererStartsWithoutModelBoundsAndReportsMissingFiles() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = PMXStageAvatarRenderer(device: device)
        let missingURL = URL(
            fileURLWithPath: "/tmp/missing-(UUID().uuidString).pmx"
        )

        #expect(renderer.localBounds == nil)
        #expect(
            throws: PMXStageAvatarRenderer.LoadError.cannotReadModel(
                fileName: missingURL.lastPathComponent
            )
        ) {
            try renderer.loadModel(from: missingURL)
        }
    }

    @Test
    func rootPlaybackPreservesAllAuthoredTranslation() throws {
        let rootTranslation = CAKeyframeAnimation(
            keyPath: "/全ての親.transform.translation.x"
        )
        rootTranslation.values = [0, 4]
        let centerTranslation = CAKeyframeAnimation(
            keyPath: "/センター.transform.translation.z"
        )
        centerTranslation.values = [0, 8]
        let centerVerticalTranslation = CAKeyframeAnimation(
            keyPath: "/センター.transform.translation.y"
        )
        centerVerticalTranslation.values = [0, 3]
        let rootRotation = CAKeyframeAnimation(
            keyPath: "/全ての親.transform.quaternion"
        )
        let armTranslation = CAKeyframeAnimation(
            keyPath: "/左腕.transform.translation.x"
        )
        let group = CAAnimationGroup()
        group.animations = [
            rootTranslation,
            centerTranslation,
            centerVerticalTranslation,
            rootRotation,
            armTranslation,
        ]

        let model = MMDNode()
        let prepared = PMXStageAvatarRenderer.preparedMotion(
            group,
            for: model,
            rootMotionEnabled: false
        )
        let keyPaths = try #require(prepared.animations).compactMap {
            ($0 as? CAKeyframeAnimation)?.keyPath
        }

        #expect(keyPaths == [
            "/全ての親.transform.translation.x",
            "/センター.transform.translation.z",
            "/センター.transform.translation.y",
            "/全ての親.transform.quaternion",
            "/左腕.transform.translation.x",
        ])
    }

    @Test
    func modelMotionDropsVMDSceneCameraAndLightTracks() throws {
        let bone = CAKeyframeAnimation(
            keyPath: "/上半身.transform.quaternion"
        )
        let camera = CAKeyframeAnimation(
            keyPath: "/MMDCamera.camera.yFov"
        )
        let cameraPosition = CAKeyframeAnimation(
            keyPath: "transform.translation.x"
        )
        let light = CAKeyframeAnimation(keyPath: "light.color")
        let group = CAAnimationGroup()
        group.animations = [bone, camera, cameraPosition, light]

        let modelMotion = PMXStageAvatarRenderer.motionByRemovingSceneTracks(
            from: group
        )
        let keyPaths = try #require(modelMotion.animations).compactMap {
            ($0 as? CAKeyframeAnimation)?.keyPath
        }

        #expect(keyPaths == ["/上半身.transform.quaternion"])
    }

    @Test
    func attachesVMDAnimationGroupToMMDModel() {
        let model = MMDNode()
        let rotation = CAKeyframeAnimation(
            keyPath: "/上半身.transform.quaternion"
        )
        rotation.values = [
            NSValue(scnVector4: SCNVector4(0, 0, 0, 1)),
        ]
        let group = CAAnimationGroup()
        group.animations = [rotation]
        group.duration = 1

        PMXStageAvatarRenderer.attachMotion(
            group,
            to: model,
            key: "test-motion",
            rootMotionEnabled: false
        )

        #expect(model.animationKeys.contains("test-motion"))
    }

    @Test
    func oneShotMotionDoesNotResetToItsFirstFrame() throws {
        let model = MMDNode()
        let root = CAKeyframeAnimation(
            keyPath: "/センター.transform.translation.z"
        )
        root.values = [Float(0), Float(16)]
        root.keyTimes = [0, 1]
        let motion = CAAnimationGroup()
        motion.animations = [root]
        motion.duration = 1

        PMXStageAvatarRenderer.attachMotion(
            motion,
            to: model,
            key: "one-shot",
            rootMotionEnabled: false,
            repeats: false
        )

        let player = try #require(model.animationPlayer(forKey: "one-shot"))
        #expect(player.animation.repeatCount == 0)
        #expect(!player.animation.isRemovedOnCompletion)
    }

    @Test
    func loadErrorsProvideLocalizedDescriptions() {
        let missing = PMXStageAvatarRenderer.LoadError.cannotReadModel(
            fileName: "missing.pmx"
        )
        let invalidMotion = PMXStageAvatarRenderer.LoadError.invalidMotion(
            fileName: "broken.vmd"
        )

        #expect(missing.errorDescription == "无法读取 PMX 模型“missing.pmx”。")
        #expect(invalidMotion.errorDescription == "VMD 动作“broken.vmd”格式无效。")
    }

    @Test
    func desktopViewConfigurationUsesTransparentMetalSurface() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: .zero, device: device)

        PMXAvatarMetalView.configureMetalSurface(view)

        #expect(view.colorPixelFormat == .bgra8Unorm_srgb)
        #expect(view.depthStencilPixelFormat == .depth32Float)
        #expect(view.clearColor.alpha == 0)
        #expect(view.isPaused == false)
        #expect(view.framebufferOnly)
    }

    private static func emptyPMXData() -> Data {
        var data = Data("PMX ".utf8)
        appendUInt32(Float32(2).bitPattern, to: &data)
        data.append(contentsOf: [8, 1, 0, 1, 1, 1, 1, 1, 1])
        for _ in 0..<4 {
            appendUInt32(0, to: &data)
        }
        for _ in 0..<9 {
            appendUInt32(0, to: &data)
        }
        return data
    }

    private static func emptyVMDData() -> Data {
        var data = fixedWidthData("Vocaloid Motion Data 0002", count: 30)
        data.append(fixedWidthData("gmgn radio", count: 20))
        appendUInt32(0, to: &data)
        appendUInt32(0, to: &data)
        return data
    }

    private static func fixedWidthData(_ string: String, count: Int) -> Data {
        var bytes = Array(string.utf8.prefix(count))
        bytes.append(contentsOf: repeatElement(0, count: count - bytes.count))
        return Data(bytes)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
