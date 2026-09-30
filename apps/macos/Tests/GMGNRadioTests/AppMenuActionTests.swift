import Foundation
import Testing
import WorldRuntime
@testable import GMGNRadio

@Test
func characterMotionMenuOnlyIncludesTheFourProductMotionsInProductOrder() {
    let motions = [
        StageMotionAsset(
            id: "gmgn.motion.local-preview-dance-pmx",
            name: "Local Preview Dance PMX",
            format: .vmd,
            url: URL(fileURLWithPath: "/tmp/preview.vmd")
        ),
        StageMotionAsset(
            id: MotionPackageStore.naturalIdleID,
            name: "自然待机",
            format: .procedural,
            url: nil
        ),
        StageMotionAsset(
            id: MotionPackageStore.iluvSlapBassID,
            name: "I Love Slap Bass",
            format: .vmd,
            url: URL(fileURLWithPath: "/tmp/slap-bass.vmd")
        ),
        StageMotionAsset(
            id: CharacterMotionMenuPolicy.ardyJumpingJacksID,
            name: "ARDY 自然开合跳",
            format: .vmd,
            url: URL(fileURLWithPath: "/tmp/jumping-jacks.vmd")
        ),
        StageMotionAsset(
            id: CharacterMotionMenuPolicy.ardyBackflipID,
            name: "ARDY Backflip",
            format: .vmd,
            url: URL(fileURLWithPath: "/tmp/backflip.vmd")
        ),
    ]

    let items = CharacterMotionMenuPolicy.items(
        motions: motions,
        activeMotionID: MotionPackageStore.iluvSlapBassID
    )

    #expect(items.map(\.id) == [
        MotionPackageStore.naturalIdleID,
        MotionPackageStore.iluvSlapBassID,
        CharacterMotionMenuPolicy.ardyJumpingJacksID,
        CharacterMotionMenuPolicy.ardyBackflipID,
    ])
    #expect(items.map(\.name) == ["待机", "Slap Bass", "ARDY 开合跳", "后空翻"])
    #expect(items.map(\.isActive) == [false, true, false, false])
}

@Test
func livingActivityMenuIncludesEveryAuthoredActivityWithReadableNames() {
    let definitions = [
        LifeActivityDefinition(
            id: "home.idle",
            activity: .idle,
            phases: [],
            interruptible: true,
            cooldownSeconds: 0
        ),
        LifeActivityDefinition(
            id: "home.turn",
            activity: .turn(targetYaw: 0),
            phases: [],
            interruptible: true,
            cooldownSeconds: 0
        ),
        LifeActivityDefinition(
            id: "home.walk",
            activity: .walk(destinationID: "wp.center"),
            phases: [],
            interruptible: true,
            cooldownSeconds: 0
        ),
        LifeActivityDefinition(
            id: "chair.sit",
            activity: .sit(anchorID: "chair.sit"),
            phases: [],
            interruptible: true,
            cooldownSeconds: 0
        ),
        LifeActivityDefinition(
            id: "window.gaze",
            activity: .gaze(targetID: "window.gaze"),
            phases: [],
            interruptible: true,
            cooldownSeconds: 0
        ),
        LifeActivityDefinition(
            id: "music.listen",
            activity: .listenMusic(anchorID: "music.listen"),
            phases: [],
            interruptible: true,
            cooldownSeconds: 0
        ),
        LifeActivityDefinition(
            id: "kitchen.walk",
            displayName: "走到厨房操作台",
            activity: .walk(destinationID: "wp.kitchen.counter"),
            phases: [],
            interruptible: true,
            cooldownSeconds: 0
        ),
        LifeActivityDefinition(
            id: "dining.walk",
            displayName: "走到餐桌旁",
            activity: .walk(destinationID: "wp.dining.table"),
            phases: [],
            interruptible: true,
            cooldownSeconds: 0
        ),
    ]

    let items = LivingWorldActivityMenuPolicy.items(definitions: definitions)

    #expect(items.map(\.id) == definitions.map(\.id))
    #expect(
        items.map(\.name) == [
            "自然待机",
            "原地转身",
            "走到房间中央",
            "坐到椅子上",
            "看向窗外",
            "听音乐并跳舞（循环）",
            "走到厨房操作台",
            "走到餐桌旁",
        ]
    )
}

@Test
func startingALivingActivityNeverPresentsTheLiveCam() {
    // 活动开始不是「进入小窗」的动作。旧测试只断言「空间开着时不该切」，
    // 空间没开时那条策略一律回答「该显示小窗」，于是活动把小窗顶了出来。
    #expect(
        !LiveCamPresentationPolicy.shouldPresentLiveCam(
            trigger: .livingWorldActivityChange,
            hasAvatar: true,
            fullStageIsPresented: false
        )
    )
    #expect(
        !LiveCamPresentationPolicy.shouldPresentLiveCam(
            trigger: .livingWorldActivityChange,
            hasAvatar: true,
            fullStageIsPresented: true
        )
    )
}

@Test
func selectingACharacterMotionNeverPresentsTheLiveCam() {
    #expect(
        !LiveCamPresentationPolicy.shouldPresentLiveCam(
            trigger: .characterMotionChange,
            hasAvatar: true,
            fullStageIsPresented: false
        )
    )
}

@Test
func residentStateNoticesAndSnapshotChangesNeverPresentTheLiveCam() {
    // 语音、状态播报、走路与许愿任务变化都不许改变窗口形态。
    for trigger in [
        LiveCamPresentationTrigger.residentStatusNotice,
        .avatarSnapshotChange,
    ] {
        #expect(
            !LiveCamPresentationPolicy.shouldPresentLiveCam(
                trigger: trigger,
                hasAvatar: true,
                fullStageIsPresented: false
            )
        )
    }
    // 保留项：用户的显式小窗动作仍然有效（还有角色、空间没占着渲染面）。
    #expect(
        LiveCamPresentationPolicy.shouldPresentLiveCam(
            trigger: .explicitUserAction,
            hasAvatar: true,
            fullStageIsPresented: false
        )
    )
    // 冷启动的默认入口是唯一允许的非显式呈现。
    #expect(
        LiveCamPresentationPolicy.shouldPresentLiveCam(
            trigger: .launchDefault,
            hasAvatar: true,
            fullStageIsPresented: false
        )
    )
}

@Test
func startingOrChangingMusicPreservesTheCurrentWindowMode() {
    #expect(!MusicPlaybackPresentationPolicy.opensFullStageOnPlaybackStart)
}

@Test
func aFinishedOneShotReturnsToIdleOnlyWhileItIsStillSelected() {
    let completedURL = URL(fileURLWithPath: "/tmp/backflip.vmd")
    let backflip = StageMotionAsset(
        id: CharacterMotionMenuPolicy.ardyBackflipID,
        name: "后空翻",
        format: .vmd,
        url: completedURL,
        loop: false
    )
    let replacement = StageMotionAsset(
        id: MotionPackageStore.iluvSlapBassID,
        name: "Slap Bass",
        format: .vmd,
        url: URL(fileURLWithPath: "/tmp/slap-bass.vmd")
    )

    #expect(
        StageMotionCompletionPolicy.shouldReturnToNaturalIdle(
            completedURL: completedURL,
            selectedMotion: backflip
        )
    )
    #expect(
        !StageMotionCompletionPolicy.shouldReturnToNaturalIdle(
            completedURL: completedURL,
            selectedMotion: replacement
        )
    )
}

@Test
@MainActor
func livingActivityMenuStorePublishesDefinitionsLoadedAfterLaunch() {
    let store = LivingWorldActivityMenuStore()
    let definition = LifeActivityDefinition(
        id: "kitchen.walk",
        displayName: "走到厨房操作台",
        activity: .walk(destinationID: "wp.kitchen.counter"),
        phases: [],
        interruptible: true,
        cooldownSeconds: 0
    )

    #expect(store.items.isEmpty)

    store.update(definitions: [definition])

    #expect(store.items == [
        LivingWorldActivityMenuItem(
            id: "kitchen.walk",
            name: "走到厨房操作台"
        ),
    ])
}

@Test
func livingWorldActivityMotionsAreFilteredForTheCurrentAvatarFormat() {
    let vmd = StageMotionAsset(
        id: "listen.music",
        name: "PMX Dance",
        format: .vmd,
        url: URL(fileURLWithPath: "/tmp/dance.vmd")
    )
    let vrma = StageMotionAsset(
        id: "listen.sway",
        name: "VRM Sway",
        format: .vrma,
        url: URL(fileURLWithPath: "/tmp/sway.vrma")
    )

    #expect(
        LivingWorldAvatarPresentationPolicy.compatibleMotions(
            [vmd.id: vmd, vrma.id: vrma],
            avatarFormat: .pmx
        ) == [vmd.id: vmd]
    )
    #expect(
        LivingWorldAvatarPresentationPolicy.compatibleMotions(
            [vmd.id: vmd, vrma.id: vrma],
            avatarFormat: .vrm
        ) == [vrma.id: vrma]
    )
}

@Test
@MainActor
func livingWorldStageEntryRequestsTheWorldBeforeShowingTheWindow() {
    let spatialStage = SpatialStageStore()
    var worldWasRequestedWhenShown = false
    let action = LivingWorldStageEntryAction(
        requestWorldPresentation: {
            spatialStage.requestWorldPresentation()
        },
        showStageWindow: {
            worldWasRequestedWhenShown = spatialStage
                .isWorldPresentationRequested
        }
    )

    action.perform()

    #expect(spatialStage.isWorldPresentationRequested)
    #expect(worldWasRequestedWhenShown)
}

@Test
func systemResidentMenuPresentsOnlyEntryActionsInFixedOrder() {
    // P1 空间优先：电台插件关闭（默认）时菜单不含「打开播放器」。
    // 装修入口属于空间那一组，不在门禁控制范围内，紧跟「进入空间」。
    #expect(
        SystemResidentMenuPolicy.entries(isRadioPluginEnabled: false) == [
            .showLiveCam,
            .enterSpace,
            .toggleDecoration,
            .settings,
            .quit,
        ]
    )
    // 插件打开时恢复改动前的完整条目与顺序（`.openPlayer` 及其按钮实现全部保留）；
    // 装修入口插在「进入空间」与「打开播放器」之间，原有四条的相对顺序不变。
    #expect(
        SystemResidentMenuPolicy.entries(isRadioPluginEnabled: true) == [
            .showLiveCam,
            .enterSpace,
            .toggleDecoration,
            .openPlayer,
            .settings,
            .quit,
        ]
    )
}

@Test
func decorationMenuTitleFollowsTheDecorationState() {
    #expect(StageDecorationMenuTitle.resolve(isDecorating: false) == "装修空间")
    #expect(StageDecorationMenuTitle.resolve(isDecorating: true) == "结束装修")
}

@Test
@MainActor
func decorationEntryPresentsTheSpaceBeforeTogglingTheEditorInOneStep() {
    var isDecorating = false
    var calls: [String] = []
    let action = StageDecorationEntryAction(
        isDecorationEditorOpen: { isDecorating },
        showStage: { calls.append("showStage") },
        toggleDecorationEditor: {
            calls.append("toggleDecorationEditor")
            isDecorating.toggle()
        }
    )

    // 进入装修：先呈现空间，再开编辑器 —— 一次点击就够。
    action.perform()
    #expect(calls == ["showStage", "toggleDecorationEditor"])
    #expect(isDecorating)

    // 结束装修：只退出装修，不重新呈现空间。
    action.perform()
    #expect(calls == ["showStage", "toggleDecorationEditor", "toggleDecorationEditor"])
    #expect(!isDecorating)
}

@Test
@MainActor
func appMenuActionsForwardToTheAdaptedApplicationController() {
    let controller = ApplicationControllerSpy()

    AppMenuAction.startAIProgram.perform(on: controller)
    AppMenuAction.showStage.perform(on: controller)
    AppMenuAction.showPlayer.perform(on: controller)
    AppMenuAction.showLiveCam.perform(on: controller)
    AppMenuAction.toggleDecorationEditor.perform(on: controller)
    AppMenuAction.playCharacterMotion(id: "builtin.motion.iluvslapbass")
        .perform(on: controller)
    AppMenuAction.runLivingActivity(id: "window.gaze").perform(on: controller)
    AppMenuAction.stopLivingActivity.perform(on: controller)
    AppMenuAction.closeStage.perform(on: controller)
    AppMenuAction.chooseLocalTrack.perform(on: controller)
    AppMenuAction.toggleLocalPlayback.perform(on: controller)
    AppMenuAction.toggleLyricsVisualMode.perform(on: controller)
    AppMenuAction.exitImmersiveVisuals.perform(on: controller)

    #expect(controller.startAIProgramCallCount == 1)
    #expect(controller.showStageCallCount == 1)
    #expect(controller.showPlayerCallCount == 1)
    #expect(controller.showLiveCamCallCount == 1)
    #expect(controller.toggleDecorationEditorCallCount == 1)
    #expect(
        controller.playedCharacterMotionIDs
            == ["builtin.motion.iluvslapbass"]
    )
    #expect(controller.livingActivityIDs == ["window.gaze"])
    #expect(controller.stopLivingActivityCallCount == 1)
    #expect(controller.closeStageCallCount == 1)
    #expect(controller.chooseLocalTrackCallCount == 1)
    #expect(controller.toggleLocalPlaybackCallCount == 1)
    #expect(controller.toggleLyricsVisualModeCallCount == 1)
    #expect(controller.exitImmersiveVisualsCallCount == 1)
}

@MainActor
private final class ApplicationControllerSpy: GMGNApplicationControlling {
    private(set) var startAIProgramCallCount = 0
    private(set) var showStageCallCount = 0
    private(set) var showPlayerCallCount = 0
    private(set) var showLiveCamCallCount = 0
    private(set) var toggleDecorationEditorCallCount = 0
    private(set) var playedCharacterMotionIDs: [String] = []
    private(set) var livingActivityIDs: [String] = []
    private(set) var stopLivingActivityCallCount = 0
    private(set) var closeStageCallCount = 0
    private(set) var chooseLocalTrackCallCount = 0
    private(set) var toggleLocalPlaybackCallCount = 0
    private(set) var toggleLyricsVisualModeCallCount = 0
    private(set) var exitImmersiveVisualsCallCount = 0

    func startAIProgram() {
        startAIProgramCallCount += 1
    }

    func showStage() {
        showStageCallCount += 1
    }

    func showPlayer() {
        showPlayerCallCount += 1
    }

    func showLiveCam() {
        showLiveCamCallCount += 1
    }

    func toggleDecorationEditor() {
        toggleDecorationEditorCallCount += 1
    }

    func playCharacterMotion(id: String) {
        playedCharacterMotionIDs.append(id)
    }

    func runLivingWorldActivity(id: String) {
        livingActivityIDs.append(id)
    }

    func stopLivingWorldActivity() {
        stopLivingActivityCallCount += 1
    }

    func closeStage() {
        closeStageCallCount += 1
    }

    func chooseLocalTrack() {
        chooseLocalTrackCallCount += 1
    }

    func toggleLocalPlayback() {
        toggleLocalPlaybackCallCount += 1
    }

    func toggleLyricsVisualMode() {
        toggleLyricsVisualModeCallCount += 1
    }

    func exitImmersiveVisuals() {
        exitImmersiveVisualsCallCount += 1
    }
}
