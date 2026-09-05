import AppKit
import Foundation
import simd
import Testing
@testable import GMGNRadio

@Test
func marbleViewportUsesTheActualDrawableSizeBeforeItsResizeCallback() {
    let resolved = MarbleViewportMetrics.resolve(
        reportedSize: .zero,
        drawableSize: CGSize(width: 1920, height: 1080)
    )

    #expect(resolved == CGSize(width: 1920, height: 1080))
}

@Test
func marbleSceneFramingRecentersAndNormalizesTheWorld() {
    let framing = MarbleSceneFraming(
        positions: [
            SIMD3<Float>(8, -6, -2),
            SIMD3<Float>(12, -2, 8),
        ]
    )

    #expect(framing.center == SIMD3<Float>(10, -4, 3))
    #expect(framing.groundedOrigin == SIMD3<Float>(10, -6, 3))
    #expect(abs(framing.uniformScale - 0.4) < 0.0001)
}

@Test
func marbleSceneFramingProducesTheColliderTransform() {
    let framing = MarbleSceneFraming(
        positions: [
            SIMD3<Float>(-2, -1, -3),
            SIMD3<Float>(2, 3, 1),
        ]
    )
    let transform = framing.colliderTransform(
        sourceCoordinates: .worldLabsOpenCV
    )

    #expect(
        transform.apply(SIMD3<Float>(2, 1, 3))
            == framing.normalize([SIMD3<Float>(2, -1, -3)])[0]
    )
}

@Test
func marbleSceneFramingPlacesTheCameraInsideTheRoomVolume() {
    let framing = MarbleSceneFraming(
        positions: [
            SIMD3<Float>(-1.1965, -0.9802, -4.1594),
            SIMD3<Float>(1.2263, 1.1995, 1.8604),
        ]
    )

    let home = framing.recommendedCameraHome(
        worldID: "world-labs-example-warm-kitchen"
    )

    #expect(abs(home.position.x) < 0.0001)
    #expect(home.position.y > 0.7)
    #expect(home.position.y < 0.9)
    #expect(home.position.z > 1)
    #expect(home.position.z < 1.2)
    #expect(home.yaw == 0)
    #expect(home.pitch == 0)
}

@Test
func marbleAvatarPlacementAvoidsAnOccupiedWallInFrontOfTheCamera() {
    let camera = SpatialCameraState(
        position: SIMD3<Float>(0, 0.8, 1.1),
        yaw: 0,
        pitch: 0
    )
    var points: [SIMD3<Float>] = []
    for x in stride(from: Float(-0.8), through: 0.8, by: 0.08) {
        for z in stride(from: Float(-0.3), through: 0.8, by: 0.08) {
            points.append(SIMD3<Float>(x, 0.02, z))
        }
    }
    for y in stride(from: Float(0.15), through: 1.5, by: 0.06) {
        for x in stride(from: Float(-0.22), through: 0.22, by: 0.04) {
            points.append(SIMD3<Float>(x, y, 0.2))
        }
    }

    let placement = StageAvatarPlacementSolver.resolve(
        normalizedPoints: points,
        camera: camera,
        scene: .cosyWoodHouse
    )

    #expect(abs(placement.position.x) >= 0.2)
    #expect(placement.position.z > -0.3)
    #expect(abs(placement.position.y - 0.02) < 0.001)
}

@Test
func marbleAvatarPlacementAccountsForTheVisibleSizeOfLargeSplats() {
    let camera = SpatialCameraState(
        position: SIMD3<Float>(0, 0.8, 1.1),
        yaw: 0,
        pitch: 0
    )
    var samples: [SpatialSplatSample] = []
    for x in stride(from: Float(-0.9), through: 0.9, by: 0.08) {
        for z in stride(from: Float(-0.4), through: 0.8, by: 0.08) {
            samples.append(SpatialSplatSample(
                position: SIMD3<Float>(x, 0.01, z),
                horizontalRadius: 0.025,
                verticalRadius: 0.01
            ))
        }
    }
    let cabinet = SpatialSplatSample(
        position: SIMD3<Float>(0.34, 0.78, 0.38),
        horizontalRadius: 0.42,
        verticalRadius: 0.65
    )
    samples.append(cabinet)

    let placement = StageAvatarPlacementSolver.resolve(
        normalizedSamples: samples,
        camera: camera,
        scene: .cosyWoodHouse
    )
    let horizontalDistance = simd_distance(
        SIMD2<Float>(placement.position.x, placement.position.z),
        SIMD2<Float>(cabinet.position.x, cabinet.position.z)
    )

    #expect(horizontalDistance > cabinet.horizontalRadius + 0.2)
}

@Test
func marbleAvatarLoadPlanKeepsThePMXResourceBoundaryAndVMDMotion() throws {
    let root = URL(fileURLWithPath: "/tmp/avatar")
    let model = root.appending(path: "model.pmx")
    let motion = root.appending(path: "dance.vmd")
    let snapshot = StageAvatarRuntimeSnapshot(
        avatar: StageAvatarAsset(
            id: "pmx.avatar",
            name: "PMX Avatar",
            format: .pmx,
            modelURL: model,
            resourceRootURL: root
        ),
        motion: StageMotionAsset(
            id: "vmd.motion",
            name: "Dance",
            format: .vmd,
            url: motion
        ),
        revision: 1
    )

    #expect(
        try MarbleAvatarLoadPlan.resolve(snapshot) == .pmx(
            modelURL: model,
            resourceRootURL: root,
            motionURL: motion
        )
    )
}

@Test
func marbleAvatarLoadPlanTreatsProceduralMotionAsPMXRestPose() throws {
    let root = URL(fileURLWithPath: "/tmp/avatar")
    let model = root.appending(path: "model.pmx")
    let snapshot = StageAvatarRuntimeSnapshot(
        avatar: StageAvatarAsset(
            id: "pmx.avatar",
            name: "PMX Avatar",
            format: .pmx,
            modelURL: model,
            resourceRootURL: root
        ),
        motion: StageMotionAsset(
            id: MotionPackageStore.naturalIdleID,
            name: "Natural Idle",
            format: .procedural,
            url: nil
        ),
        revision: 1
    )

    #expect(
        try MarbleAvatarLoadPlan.resolve(snapshot) == .pmx(
            modelURL: model,
            resourceRootURL: root,
            motionURL: nil
        )
    )
}

@Test
func marbleAvatarLoadPlanRejectsVRMAForPMX() {
    let root = URL(fileURLWithPath: "/tmp/avatar")
    let snapshot = StageAvatarRuntimeSnapshot(
        avatar: StageAvatarAsset(
            id: "pmx.avatar",
            name: "PMX Avatar",
            format: .pmx,
            modelURL: root.appending(path: "model.pmx"),
            resourceRootURL: root
        ),
        motion: StageMotionAsset(
            id: "vrma.motion",
            name: "VRMA",
            format: .vrma,
            url: root.appending(path: "dance.vrma")
        ),
        revision: 1
    )

    #expect(throws: MarbleAvatarLoadError.pmxRequiresVMD) {
        try MarbleAvatarLoadPlan.resolve(snapshot)
    }
}

@Test
func marblePMXFramingNormalizesFeetToTheExistingPlacementOrigin() {
    let transform = MarblePMXFraming.modelTransform(
        bounds: PMXAvatarBounds(
            minimum: SIMD3<Float>(-5, 2, -3),
            maximum: SIMD3<Float>(5, 22, 3)
        ),
        placement: StageAvatarPlacement(
            position: SIMD3<Float>(1, 2, 3),
            scale: 0.8,
            yaw: 0
        )
    )
    let feetCenter = transform * SIMD4<Float>(0, 2, 0, 1)
    let headCenter = transform * SIMD4<Float>(0, 22, 0, 1)

    #expect(
        simd_distance(
            SIMD3<Float>(feetCenter.x, feetCenter.y, feetCenter.z),
            SIMD3<Float>(1, 2, 3)
        ) < 0.0001
    )
    #expect(abs((headCenter.y - feetCenter.y) - 1.36) < 0.0001)
}

@Test
func marblePMXFramingUsesTheSoleInsteadOfAnAccessoryBelowTheFeet() {
    let bounds = PMXAvatarBounds(
        minimum: SIMD3<Float>(-5, -8, -3),
        maximum: SIMD3<Float>(5, 22, 3)
    )
    let placement = StageAvatarPlacement(
        position: SIMD3<Float>(1, 0.04, 3),
        scale: 0.8,
        yaw: 0
    )
    let soleReferenceY: Float = 2
    let transform = MarblePMXFraming.modelTransform(
        bounds: bounds,
        placement: placement,
        soleReferenceY: soleReferenceY
    )
    let sole = transform * SIMD4<Float>(0, soleReferenceY, 0, 1)
    let crown = transform * SIMD4<Float>(0, bounds.maximum.y, 0, 1)

    #expect(abs(sole.y - placement.position.y) < 0.0001)
    #expect(abs((crown.y - sole.y) - 1.36) < 0.0001)
}

@Test
func warmKitchenPMXAvatarUsesHumanScaleRelativeToTheRoom() throws {
    let calibration = try #require(
        SpatialWorldCalibration.resolve(
            worldID: "world-labs-example-warm-kitchen"
        )
    )
    let placement = try #require(calibration.avatarPlacement)
    let bounds = PMXAvatarBounds(
        minimum: SIMD3<Float>(-42, 0, -18),
        maximum: SIMD3<Float>(42, 170.323, 18)
    )
    let transform = MarblePMXFraming.modelTransform(
        bounds: bounds,
        placement: placement
    )
    let sole = transform * SIMD4<Float>(0, bounds.minimum.y, 0, 1)
    let crown = transform * SIMD4<Float>(0, bounds.maximum.y, 0, 1)
    let normalizedHeight = crown.y - sole.y

    #expect(normalizedHeight >= 0.75)
    #expect(normalizedHeight <= 0.78)
}

@Test
func marblePMXFramingGroundsTheAnimatedSoleInsteadOfTheRestPose() {
    let bounds = PMXAvatarBounds(
        minimum: SIMD3<Float>(-5, 2, -3),
        maximum: SIMD3<Float>(5, 22, 3)
    )
    let placement = StageAvatarPlacement(
        position: SIMD3<Float>(1, 0.04, 3),
        scale: 0.8,
        yaw: 0
    )
    let restFootReferenceY: Float = 4
    let animatedFootReferenceY: Float = 7
    let animatedSoleY = bounds.minimum.y
        + animatedFootReferenceY
        - restFootReferenceY
    let groundingOffsetY = PMXAnimatedGrounding.localOffsetY(
        restFootReferenceY: restFootReferenceY,
        animatedFootReferenceY: animatedFootReferenceY
    )
    let transform = MarblePMXFraming.modelTransform(
        bounds: bounds,
        placement: placement,
        localGroundingOffsetY: groundingOffsetY
    )
    let groundedSole = transform * SIMD4<Float>(0, animatedSoleY, 0, 1)

    #expect(abs(groundedSole.y - placement.position.y) < 0.0001)
}

@Test
func marblePMXFullStageKeepsCameraAndModelTransformsSeparate() {
    let bounds = PMXAvatarBounds(
        minimum: SIMD3<Float>(-5, 2, -3),
        maximum: SIMD3<Float>(5, 22, 3)
    )
    let placement = StageAvatarPlacement(
        position: SIMD3<Float>(0, 0, -0.58),
        scale: 0.8,
        yaw: 0
    )
    let camera = SpatialCameraState(
        position: SIMD3<Float>(0, 1.45, 1.75),
        yaw: 0,
        pitch: 0
    )
    let sharedView = simd_float4x4(
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(
            -camera.position.x,
            -camera.position.y,
            -camera.position.z,
            1
        )
    )
    let matrices = MarblePMXRenderMatrices.fullStage(
        bounds: bounds,
        placement: placement,
        sharedCameraView: sharedView
    )
    let expectedModel = MarblePMXFraming.modelTransform(
        bounds: bounds,
        placement: placement
    )

    for column in 0..<4 {
        #expect(
            simd_distance(
                matrices.cameraView[column],
                sharedView[column]
            ) < 0.0001
        )
        #expect(
            simd_distance(
                matrices.modelTransform[column],
                expectedModel[column]
            ) < 0.0001
        )
    }
}

@Test
func macOSAppBuildEnablesSigningForMicrophoneEntitlements() throws {
    let macOSRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let projectYAML = try String(
        contentsOf: macOSRoot.appendingPathComponent("project.yml"),
        encoding: .utf8
    )
    let appTarget = try #require(
        projectYAML.components(separatedBy: "  GMGNRadioTests:").first
    )
    let testTargetAndSchemes = try #require(
        projectYAML.components(separatedBy: "  GMGNRadioTests:").dropFirst().first
    )
    let testTarget = try #require(
        testTargetAndSchemes.components(separatedBy: "schemes:").first
    )
    let xcodeProject = try String(
        contentsOf: macOSRoot
            .appendingPathComponent("GMGNRadio.xcodeproj/project.pbxproj"),
        encoding: .utf8
    )

    #expect(appTarget.contains("CODE_SIGNING_ALLOWED: YES"))
    #expect(testTarget.contains("CODE_SIGNING_ALLOWED: YES"))
    #expect(testTarget.contains("Apple Development"))
    #expect(testTarget.contains("GENERATE_INFOPLIST_FILE: YES"))
    #expect(projectYAML.contains("DEVELOPMENT_TEAM: 79J6W8QEMD"))
    #expect(appTarget.contains("CODE_SIGN_STYLE: Manual"))
    #expect(appTarget.contains("Apple Development"))
    #expect(
        xcodeProject.components(
            separatedBy: "CODE_SIGNING_ALLOWED = YES;"
        ).count >= 3
    )
    #expect(
        xcodeProject.components(
            separatedBy: "DEVELOPMENT_TEAM = 79J6W8QEMD;"
        ).count >= 3
    )
    #expect(
        xcodeProject.components(
            separatedBy: "\"CODE_SIGN_IDENTITY[sdk=macosx*]\" = \"Apple Development\";"
        ).count >= 3
    )
}

@Test
@MainActor
func stageWindowControllerReusesTheOpenWindowAndCanReopen() {
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore()
    )

    controller.show()
    let firstWindow = controller.window
    controller.show()

    #expect(controller.window === firstWindow)
    #expect(controller.isPresented)

    controller.close()

    #expect(!controller.isPresented)

    controller.show()

    #expect(controller.isPresented)
    #expect(controller.window !== firstWindow)

    controller.close()
}

@Test
@MainActor
func stageWindowControllerRunsAudioMonitoringOnlyWhilePresented() {
    let monitor = StageAudioMonitorSpy()
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore(),
        audioMonitor: monitor
    )

    controller.show()

    #expect(monitor.startCallCount == 1)

    controller.close()

    #expect(monitor.stopCallCount == 1)
}

@Test
@MainActor
func openingThePlayerDoesNotStartAFullSpaceTransition() {
    let spatialStage = SpatialStageStore()
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore(),
        spatialStage: spatialStage
    )
    var fullSpaceTransitionCount = 0
    controller.setOnWillPresentSpaceHandler {
        fullSpaceTransitionCount += 1
    }

    controller.show()

    #expect(fullSpaceTransitionCount == 0)
    controller.close()
}

@Test
@MainActor
func openingThePlayerKeepsTheLiveCamCompanionActive() {
    let spatialStage = SpatialStageStore()
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore(),
        spatialStage: spatialStage
    )
    var playerPresentationCount = 0
    controller.setOnShowPlayerHandler {
        playerPresentationCount += 1
    }

    controller.show()

    #expect(playerPresentationCount == 1)
    controller.close()
}

@Test
@MainActor
func enteringSpaceFromThePlayerStartsAFullSpaceTransition() throws {
    let spatialStage = SpatialStageStore()
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore(),
        spatialStage: spatialStage
    )
    var fullSpaceTransitionCount = 0
    controller.setOnWillPresentSpaceHandler {
        fullSpaceTransitionCount += 1
    }
    controller.show()
    fullSpaceTransitionCount = 0

    let destinationButton = try #require(
        controller.window?.contentView?
            .descendants
            .compactMap { $0 as? NSButton }
            .first {
                $0.identifier?.rawValue == "stage.destination-toggle"
            }
    )
    destinationButton.performClick(nil)

    #expect(fullSpaceTransitionCount == 1)
    controller.close()
}

@Test
@MainActor
func switchingFromSpaceToPlayerRestoresTheLiveCamCompanion() throws {
    let spatialStage = SpatialStageStore()
    spatialStage.requestWorldPresentation()
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore(),
        spatialStage: spatialStage
    )
    var playerPresentationCount = 0
    controller.setOnShowPlayerHandler {
        playerPresentationCount += 1
    }
    controller.show()

    let destinationButton = try #require(
        controller.window?.contentView?
            .descendants
            .compactMap { $0 as? NSButton }
            .first {
                $0.identifier?.rawValue == "stage.destination-toggle"
            }
    )
    destinationButton.performClick(nil)

    #expect(playerPresentationCount == 1)
    controller.close()
}

@Test
@MainActor
func playerKeepsTheSharedAvatarSurfaceInLiveCamUntilSpaceStarts() throws {
    let spatialStage = SpatialStageStore()
    let marbleLibrary = MarbleWorldLibrary(spatialStage: spatialStage)
    let renderSurfaceController = StageRenderSurfaceController(
        spatialStage: spatialStage,
        library: marbleLibrary
    )
    let liveCamContainer = NSView()
    renderSurfaceController.attachToLiveCam(liveCamContainer)
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore(),
        spatialStage: spatialStage,
        marbleLibrary: marbleLibrary,
        renderSurfaceController: renderSurfaceController
    )

    controller.show()

    #expect(renderSurfaceController.owner == .liveCam)

    let destinationButton = try #require(
        controller.window?.contentView?
            .descendants
            .compactMap { $0 as? NSButton }
            .first {
                $0.identifier?.rawValue == "stage.destination-toggle"
            }
    )
    destinationButton.performClick(nil)

    #expect(renderSurfaceController.owner == .fullStage)
    controller.close()
}

@Test
@MainActor
func localLivingPodSelectionSuspendsMarbleWorldPreparation() async {
    let spatialStage = SpatialStageStore()
    let marbleLibrary = MarbleWorldLibrary(spatialStage: spatialStage)

    marbleLibrary.selectLocalWorld(
        id: LivingPodScene.worldID,
        scene: .djHouse
    )
    let preparedURL = await marbleLibrary.prepare()

    #expect(preparedURL == nil)
    #expect(spatialStage.selectedWorldID == LivingPodScene.worldID)
    #expect(marbleLibrary.selectedWorld == nil)
    #expect(marbleLibrary.localSplatURL == nil)
}

@Test
func defaultSpacePreferenceStartsWithTheLivingPod() throws {
    let suiteName = "DefaultSpacePreferenceTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(
        DefaultSpacePreference.load(defaults: defaults) == .livingPod
    )
    #expect(
        DefaultSpacePreference.allCases.map(\.title) == [
            "飞船生活舱（Marble）",
            "上次使用的 Marble 空间",
        ]
    )
    #expect(
        GMGNSettingsSpacePage.sectionTitles == ["默认空间", "Marble 空间"]
    )
}

@Test
func defaultSpacePreferencePersistsTheLastMarbleChoice() throws {
    let suiteName = "DefaultSpacePreferencePersistence-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    DefaultSpacePreference.lastMarbleWorld.save(defaults: defaults)

    #expect(
        DefaultSpacePreference.load(defaults: defaults)
            == .lastMarbleWorld
    )
}

@Test
@MainActor
func stageWindowControllerIncludesAWindowModeButton() {
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore()
    )

    controller.show()

    let button = controller.window?.contentView?
        .descendants
        .compactMap { $0 as? NSButton }
        .first { $0.identifier?.rawValue == "stage.window-mode-toggle" }

    #expect(button != nil)
    #expect(button?.toolTip == "进入全屏")
    #expect(button?.action != nil)

    controller.close()
}

@Test
@MainActor
func stageWindowIncludesAnExpandableVisualPicker() {
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore()
    )

    controller.show()

    let descendants = controller.window?.contentView?.descendants ?? []
    let button = descendants
        .compactMap { $0 as? NSButton }
        .first { $0.identifier?.rawValue == "stage.visual-toggle" }
    let picker = descendants.first {
        $0.identifier?.rawValue == "stage.visual-picker"
    }

    #expect(button?.toolTip == "选择字幕、点阵与 MV")
    #expect(picker?.isHidden == true)

    button?.performClick(nil)

    #expect(picker?.isHidden == false)

    controller.close()
}

@Test
@MainActor
func stageComposesVideoBelowTheTransparentMetalParticles() throws {
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore()
    )

    controller.show()
    let descendants = controller.window?.contentView?.descendants ?? []
    let video = try #require(descendants.first {
        $0.identifier?.rawValue == "stage.video-background"
    })
    let particles = try #require(descendants.first {
        $0.identifier?.rawValue == "stage.metal-particles"
    })

    #expect(video.layer?.zPosition == 0)
    #expect(particles.layer?.zPosition == 1)
    #expect(particles.layer?.isOpaque == false)
    #expect(
        video.layer?.sublayers?.contains {
            $0.name == "stage.video-tone-overlay"
        } == true
    )

    controller.close()
}

@Test
@MainActor
func stageComposesTheSpatialWorldAboveParticlesWithoutCapturingInput() throws {
    let spatialStage = SpatialStageStore()
    spatialStage.requestWorldPresentation()
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore(),
        spatialStage: spatialStage
    )

    controller.show()
    let descendants = controller.window?.contentView?.descendants ?? []
    let spatialWorld = try #require(descendants.first {
        $0.identifier?.rawValue == "stage.marble-spatial-world"
    })
    let particles = try #require(descendants.first {
        $0.identifier?.rawValue == "stage.metal-particles"
    })

    #expect(
        try #require(spatialWorld.layer?.zPosition)
            > #require(particles.layer?.zPosition)
    )
    #expect(spatialWorld.hitTest(.zero) == nil)

    controller.close()
}

@Test
func stageDestinationToggleFollowsTheCurrentStageMode() {
    let spaceContent = StageDestinationContent.resolve(
        isWorldPresentationRequested: true
    )
    #expect(spaceContent.title == "播放器")
    #expect(spaceContent.symbolName == "circle.hexagongrid.fill")
    #expect(spaceContent.accessibilityLabel == "切换到播放器")
    #expect(
        StageDestinationAction.resolve(isWorldPresentationRequested: true)
            == .showPlayer
    )

    let playerContent = StageDestinationContent.resolve(
        isWorldPresentationRequested: false
    )
    #expect(playerContent.title == "空间")
    #expect(playerContent.symbolName == "cube.transparent")
    #expect(playerContent.accessibilityLabel == "进入空间")
    #expect(
        StageDestinationAction.resolve(isWorldPresentationRequested: false)
            == .enterSpace
    )
}

@Test
func stageVisualPickerShowsOnlyTheGroupsForTheCurrentMode() {
    #expect(
        StageVisualPickerGroup.visibleGroups(for: .space) == [
            .worldSelection,
            .avatarPlacement,
            .loadingStatus,
        ]
    )
    #expect(
        StageVisualPickerGroup.visibleGroups(for: .player) == [
            .lyricsEffects,
            .pointCloud,
            .particleSize,
            .musicVideo,
        ]
    )
    #expect(
        StageVisualPickerMode.resolve(isWorldPresentationRequested: true)
            == .space
    )
    #expect(
        StageVisualPickerMode.resolve(isWorldPresentationRequested: false)
            == .player
    )
}

@Test
@MainActor
func stageDestinationButtonStaysAvailableAcrossStageModes() throws {
    let spatialStage = SpatialStageStore()
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore(),
        spatialStage: spatialStage
    )

    controller.show()
    let descendants = controller.window?.contentView?.descendants ?? []
    let surfaceContainer = try #require(descendants.first {
        $0.identifier?.rawValue == "stage.shared-render-surface-container"
    })
    let destinationButton = try #require(
        descendants
            .compactMap { $0 as? NSButton }
            .first {
                $0.identifier?.rawValue == "stage.destination-toggle"
            }
    )
    let visualButton = try #require(
        descendants
            .compactMap { $0 as? NSButton }
            .first {
                $0.identifier?.rawValue == "stage.visual-toggle"
            }
    )

    #expect(surfaceContainer.isHidden)
    #expect(!destinationButton.isHidden)
    #expect(destinationButton.title == "空间")
    #expect(visualButton.toolTip == "选择字幕、点阵与 MV")

    destinationButton.performClick(nil)

    #expect(spatialStage.isWorldPresentationRequested)
    #expect(!destinationButton.isHidden)
    #expect(destinationButton.title == "播放器")
    #expect(visualButton.toolTip == "选择空间与人物位置")

    let spatialWorld = try #require(
        controller.window?.contentView?.descendants.first {
            $0.identifier?.rawValue == "stage.marble-spatial-world"
        }
    )
    #expect(spatialWorld.superview === surfaceContainer)
    #expect(surfaceContainer.isHidden)

    spatialStage.finishWorldPresentation()

    #expect(!surfaceContainer.isHidden)
    #expect(!destinationButton.isHidden)

    destinationButton.performClick(nil)

    #expect(!spatialStage.isWorldPresentationRequested)
    #expect(surfaceContainer.isHidden)
    #expect(!destinationButton.isHidden)
    #expect(destinationButton.title == "空间")
    #expect(visualButton.toolTip == "选择字幕、点阵与 MV")

    controller.close()
}

@Test
func stagePointCloudPickerIncludesTheMineradioDerivedCorePresets() {
    #expect(
        StagePointCloudChoice.allCases.map(\.title) == [
            "自动",
            "流幕",
            "星球",
            "光带",
            "封面",
            "星河",
            "滚筒",
            "留白",
        ]
    )
}

@Test
@MainActor
func stagePlaybackButtonControlsAndReflectsTheRealPlayerState() {
    var toggleCount = 0
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore(),
        playbackState: .paused,
        onTogglePlayback: { toggleCount += 1 }
    )

    controller.show()

    let button = controller.window?.contentView?
        .descendants
        .compactMap { $0 as? NSButton }
        .first { $0.identifier?.rawValue == "stage.playback-toggle" }
    #expect(button?.toolTip == "播放")
    #expect(button?.isEnabled == true)

    controller.setPlaybackState(.playing)
    #expect(button?.toolTip == "暂停")

    button?.performClick(nil)
    #expect(toggleCount == 1)

    controller.setPlaybackState(.idle)
    #expect(button?.isEnabled == false)

    controller.close()
}

@Test
@MainActor
func stageTransportActionsLiveInOneCompactControlIsland() {
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore(),
        playbackState: .playing
    )

    controller.show()
    controller.window?.contentView?.layoutSubtreeIfNeeded()

    let descendants = controller.window?.contentView?.descendants ?? []
    let controls = descendants.first {
        $0.identifier?.rawValue == "stage.transport-controls"
    }
    let playbackButton = descendants.first {
        $0.identifier?.rawValue == "stage.playback-toggle"
    }
    let windowModeButton = descendants.first {
        $0.identifier?.rawValue == "stage.window-mode-toggle"
    }
    let programButton = descendants.first {
        $0.identifier?.rawValue == "stage.program-toggle"
    }
    let previousButton = descendants.first {
        $0.identifier?.rawValue == "stage.previous-track"
    }
    let nextButton = descendants.first {
        $0.identifier?.rawValue == "stage.next-track"
    }
    let voiceButton = descendants.first {
        $0.identifier?.rawValue == "stage.voice-toggle"
    }
    let visualButton = descendants.first {
        $0.identifier?.rawValue == "stage.visual-toggle"
    }

    #expect(controls != nil)
    #expect(programButton?.superview === controls)
    #expect(previousButton?.superview === controls)
    #expect(playbackButton?.superview === controls)
    #expect(nextButton?.superview === controls)
    #expect(voiceButton?.superview === controls)
    #expect(visualButton?.superview === controls)
    #expect(windowModeButton?.superview === controls)
    controls?.layoutSubtreeIfNeeded()
    #expect(controls?.frame.size == CGSize(width: 322, height: 48))
    #expect(programButton?.frame.size == CGSize(width: 44, height: 44))
    #expect(previousButton?.frame.size == CGSize(width: 44, height: 44))
    #expect(playbackButton?.frame.size == CGSize(width: 44, height: 44))
    #expect(nextButton?.frame.size == CGSize(width: 44, height: 44))
    #expect(voiceButton?.frame.size == CGSize(width: 44, height: 44))
    #expect(visualButton?.frame.size == CGSize(width: 44, height: 44))
    #expect(windowModeButton?.frame.size == CGSize(width: 44, height: 44))

    controller.close()
}

@Test
@MainActor
func stageVoiceButtonStartsConversationAndReflectsLiveActivity() {
    var toggleCount = 0
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore(),
        voiceState: .disconnected,
        onToggleVoice: { toggleCount += 1 }
    )

    controller.show()

    let button = controller.window?.contentView?
        .descendants
        .compactMap { $0 as? NSButton }
        .first { $0.identifier?.rawValue == "stage.voice-toggle" }
    #expect(button?.toolTip == "麦克风已关闭，点击开麦")

    button?.performClick(nil)
    #expect(toggleCount == 1)

    controller.setVoiceState(.connecting)
    #expect(button?.toolTip == "正在开启麦克风，点击取消")
    #expect(button?.isEnabled == true)

    controller.setVoiceState(.listening)
    #expect(button?.toolTip == "麦克风已开启，DJ 正在听")

    controller.setVoiceState(.speaking)
    #expect(button?.toolTip == "DJ 正在说话")

    controller.setVoiceState(.connected)
    #expect(button?.toolTip == "麦克风已开启，点击关闭")
    #expect((button?.layer?.backgroundColor?.alpha ?? 0) > 0.75)
    #expect(
        button?.layer?.animation(
            forKey: "voice-active-pulse"
        ) != nil
    )

    controller.setVoiceState(.disconnected)
    #expect((button?.layer?.backgroundColor?.alpha ?? 1) < 0.1)
    #expect(
        button?.layer?.animation(
            forKey: "voice-active-pulse"
        ) == nil
    )

    controller.setVoiceState(.failed("连接 DJ 超时"))
    #expect(button?.toolTip == "开麦失败：连接 DJ 超时；点击重试")
    #expect(
        button?.image?.accessibilityDescription
            == "开麦失败：连接 DJ 超时；点击重试"
    )

    controller.close()
}

@Test
@MainActor
func stagePreviousAndNextButtonsCallTheProgramNavigationActions() {
    var previousCount = 0
    var nextCount = 0
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore(),
        playbackState: .playing,
        onPreviousTrack: { previousCount += 1 },
        onNextTrack: { nextCount += 1 }
    )

    controller.show()
    controller.setProgramNavigation(
        canGoPrevious: true,
        canGoNext: true
    )

    let buttons = controller.window?.contentView?
        .descendants
        .compactMap { $0 as? NSButton } ?? []
    let previous = buttons.first {
        $0.identifier?.rawValue == "stage.previous-track"
    }
    let next = buttons.first {
        $0.identifier?.rawValue == "stage.next-track"
    }

    #expect(previous?.toolTip == "上一首")
    #expect(next?.toolTip == "下一首")
    #expect(previous?.isEnabled == true)
    #expect(next?.isEnabled == true)

    previous?.performClick(nil)
    next?.performClick(nil)

    #expect(previousCount == 1)
    #expect(nextCount == 1)

    controller.setProgramNavigation(
        canGoPrevious: false,
        canGoNext: false
    )
    #expect(previous?.isEnabled == false)
    #expect(next?.isEnabled == false)

    controller.close()
}

@Test
@MainActor
func stageProgramButtonRevealsAndHidesTheSpatialProgramRail() {
    let store = DJProgramStore()
    store.publish(stageProgramPlan(trackCount: 6))
    store.activateSlot(at: 1)
    let controller = StageWindowController(
        audioFeatures: VisualAudioFeatureStore(),
        programStore: store,
        playbackState: .playing
    )

    controller.show()

    let descendants = controller.window?.contentView?.descendants ?? []
    let button = descendants
        .compactMap { $0 as? NSButton }
        .first { $0.identifier?.rawValue == "stage.program-toggle" }
    let rail = descendants.first {
        $0.identifier?.rawValue == "stage.program-rail"
    }

    #expect(button?.toolTip == "查看节目轨道")
    #expect(rail?.isHidden == true)

    button?.performClick(nil)

    #expect(button?.toolTip == "收起节目轨道")
    #expect(rail?.isHidden == false)

    button?.performClick(nil)

    #expect(button?.toolTip == "查看节目轨道")
    #expect(rail?.isHidden == true)

    controller.close()
}

@Test
@MainActor
func spatialProgramRailKeepsTheCompleteScrollableProgram() {
    let plan = stageProgramPlan(trackCount: 8)
    let model = StageProgramRailModel(
        plan: plan,
        activeSlotIndex: 2
    )

    #expect(model.cards.map(\.trackID) == [
        "stage-track-0",
        "stage-track-1",
        "stage-track-2",
        "stage-track-3",
        "stage-track-4",
        "stage-track-5",
        "stage-track-6",
        "stage-track-7",
    ])
    #expect(model.cards.map(\.slotIndex) == Array(0 ..< 8))
    #expect(model.cards.map(\.relativeIndex) == [-2, -1, 0, 1, 2, 3, 4, 5])
    #expect(model.cards[2].isCurrent == true)
    #expect(model.cards.map(\.depth) == [
        -144, -72, 0, -72, -144, -144, -144, -144,
    ])
    #expect(model.cards[2].opacity > model.cards[1].opacity)
    #expect(model.cards[2].opacity > model.cards[3].opacity)
}

@Test
func longProgramRailCapsTrackCardHorizontalOffset() {
    #expect(
        StageProgramRailCardLayout.horizontalOffset(
            relativeIndex: 0,
            isFocused: false
        ) == 0
    )
    #expect(
        StageProgramRailCardLayout.horizontalOffset(
            relativeIndex: 1,
            isFocused: false
        ) == 9
    )
    #expect(
        StageProgramRailCardLayout.horizontalOffset(
            relativeIndex: -1,
            isFocused: false
        ) == 9
    )
    #expect(
        StageProgramRailCardLayout.horizontalOffset(
            relativeIndex: 40,
            isFocused: false
        ) == 18
    )
    #expect(
        StageProgramRailCardLayout.horizontalOffset(
            relativeIndex: -40,
            isFocused: false
        ) == 18
    )
    #expect(
        StageProgramRailCardLayout.horizontalOffset(
            relativeIndex: 40,
            isFocused: true
        ) == -30
    )
    #expect(
        StageProgramRailCardLayout.horizontalOffset(
            relativeIndex: -40,
            isFocused: true
        ) == -30
    )
}

@Test
@MainActor
func programRailUsesAPlaylistLevelBeforeItsTrackLevel() {
    var playedSelections: [String] = []
    var replanCount = 0
    let selection = StageProgramRailSelection(
        onPlay: { programID, slotIndex in
            playedSelections.append("\(programID):\(slotIndex)")
        },
        onReplan: {
            replanCount += 1
        }
    )

    #expect(selection.route == .programs)
    selection.openProgram("night-program")
    #expect(selection.route == .tracks(programID: "night-program"))
    #expect(playedSelections.isEmpty)

    selection.activate(slotIndex: 4)

    #expect(selection.selectedSlotIndex == 4)
    #expect(playedSelections == ["night-program:4"])

    selection.showPrograms()
    #expect(selection.route == .programs)
    #expect(selection.selectedProgramID == "night-program")

    selection.replan()
    #expect(replanCount == 1)
}

@Test
func requestedWorldKeepsTheSharedSurfaceAbovePointCloudWhileLoading() {
    let state = StageSurfacePresentationState.resolve(
        isWorldPresentationRequested: true,
        isWorldVisible: false
    )

    #expect(state.isSpatialWorldHidden)
    #expect(state.isPointCloudHidden)
    #expect(state.isWorldInteractionHidden)
    #expect(!state.isLoadingIndicatorHidden)
    #expect(!state.isDestinationButtonHidden)
}

@Test
func visibleWorldHidesTheLoadingIndicatorAndShowsTheSharedSurface() {
    let state = StageSurfacePresentationState.resolve(
        isWorldPresentationRequested: true,
        isWorldVisible: true
    )

    #expect(!state.isSpatialWorldHidden)
    #expect(state.isPointCloudHidden)
    #expect(!state.isWorldInteractionHidden)
    #expect(state.isLoadingIndicatorHidden)
    #expect(!state.isDestinationButtonHidden)
}

@Test
func worldCameraDragUsesWindowLocationsWhenEventDeltasAreZero() {
    let delta = StagePointerDragDelta.resolve(
        previousLocation: CGPoint(x: 10, y: 20),
        currentLocation: CGPoint(x: 40, y: 5),
        eventDelta: .zero
    )

    #expect(delta.width == 30)
    #expect(delta.height == 15)
}

@Test
@MainActor
func programRailOpensAndPlaysASyncedMusicPlaylist() {
    let playlist = MusicPlaylistSnapshot(
        id: "netease:playlist:liked",
        providerID: .netease,
        name: "我喜欢的音乐",
        artworkURL: URL(string: "https://example.com/liked.jpg"),
        tracks: [
            stageCandidate(index: 0),
            stageCandidate(index: 1),
        ]
    )
    let libraryStore = SyncedMusicLibraryStore()
    libraryStore.merge(playlists: [playlist])
    var playedSelections: [String] = []
    let selection = StageProgramRailSelection(
        onPlayPlaylist: { playlistID, trackIndex in
            playedSelections.append("\(playlistID):\(trackIndex)")
        }
    )

    selection.openPlaylist(playlist.id)
    #expect(selection.route == .playlistTracks(playlistID: playlist.id))

    let model = StageProgramRailModel(
        playlist: libraryStore.playlists[0],
        activeTrackID: nil
    )
    #expect(model.title == "我喜欢的音乐")
    #expect(model.cards.map(\.trackID) == ["stage-track-0", "stage-track-1"])

    selection.activate(slotIndex: 1)
    #expect(playedSelections == ["netease:playlist:liked:1"])
}

@Test
func syncedPlaylistProgramKeepsTheProviderTrackOrder() {
    let playlist = MusicPlaylistSnapshot(
        id: "netease:playlist:liked",
        providerID: .netease,
        name: "我喜欢的音乐",
        artworkURL: nil,
        tracks: (0 ..< 12).map(stageCandidate(index:))
    )

    let plan = SyncedPlaylistProgramBuilder.makePlan(
        from: playlist,
        generatedAt: Date(timeIntervalSince1970: 100)
    )

    #expect(plan.brief.id == playlist.id)
    #expect(plan.title == playlist.name)
    #expect(plan.slots.map(\.track.id) == playlist.tracks.map(\.id))
    #expect(plan.slots.count == 12)
}

@Test
func syncedPlaylistDoesNotAppearTwiceAfterItStartsPlaying() {
    let playlist = MusicPlaylistSnapshot(
        id: "netease:playlist:liked",
        providerID: .netease,
        name: "我喜欢的音乐",
        artworkURL: nil,
        tracks: [stageCandidate(index: 0)]
    )
    let plan = SyncedPlaylistProgramBuilder.makePlan(from: playlist)
    let visible = StageProgramRailCatalog.visiblePrograms(
        [
            SavedDJProgram(
                plan: plan,
                activeSlotIndex: 0,
                updatedAt: Date()
            ),
            SavedDJProgram(
                plan: stageProgramPlan(trackCount: 5),
                activeSlotIndex: nil,
                updatedAt: Date()
            ),
        ],
        syncedPlaylists: [playlist]
    )

    #expect(visible.map(\.plan.brief.id) == ["stage-program"])
}

@MainActor
private final class StageAudioMonitorSpy: VisualAudioMonitoring {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() throws {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }
}

private func stageProgramPlan(trackCount: Int) -> ProgramPlan {
    let tracks = (0 ..< trackCount).map(stageCandidate(index:))
    return ProgramPlan(
        brief: ProgramBrief(
            id: "stage-program",
            targetDuration: 1_800,
            moodTags: ["夜晚"],
            energyArc: [0.3, 0.7, 0.4],
            conversationMode: .ambient
        ),
        slots: tracks.enumerated().map { index, track in
            ProgramSlot(
                track: track,
                role: index == 0 ? .opener : .build,
                hostHint: ProgramHostHint(
                    shouldTalkBefore: index == 0,
                    maxSentenceCount: 1,
                    selectionReason: "保持节目流动",
                    currentTrack: TrackReference(
                        id: track.id,
                        title: track.title,
                        artist: track.artist
                    ),
                    nextTrack: nil,
                    facts: [],
                    transitionIntent: nil
                )
            )
        },
        revision: 1,
        generatedAt: Date(timeIntervalSince1970: 1_000),
        replanAfterTrackCount: 3,
        title: "Afterglow",
        direction: "夜晚的流动感"
    )
}

private func stageCandidate(index: Int) -> MusicCandidate {
    MusicCandidate(
        id: "stage-track-\(index)",
        canonicalID: nil,
        providerID: .netease,
        source: .streaming,
        title: "Track \(index)",
        artist: "Artist \(index)",
        album: nil,
        duration: 240,
        isPlayable: true,
        matchScore: 1,
        userAffinity: 1,
        energy: 0.25 + Double(index) * 0.08,
        moodTags: [],
        genres: [],
        releaseYear: nil
    )
}

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
