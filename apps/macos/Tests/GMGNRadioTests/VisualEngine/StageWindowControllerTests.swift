import AppKit
import Foundation
import Testing
@testable import GMGNRadio

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
    let tracks = (0 ..< trackCount).map { index in
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

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
