import AppKit
import CoreGraphics
import Testing
@testable import GMGNRadio

@Test
@MainActor
func liveCamPanelUsesATransparentNonactivatingPortalWindow() {
    let panel = LiveCamPanel(
        frame: CGRect(x: 120, y: 80, width: 320, height: 240),
        contentView: NSView()
    )

    #expect(panel.styleMask.contains(.borderless))
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(!panel.styleMask.contains(.titled))
    #expect(panel.backgroundColor == .clear)
    #expect(!panel.isOpaque)
    #expect(!panel.hasShadow)
    #expect(panel.collectionBehavior == [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
    ])
    #expect(!panel.canBecomeKey)
    #expect(!panel.canBecomeMain)
}

@Test
@MainActor
func liveCamPanelClipsToItsConfigurableAperture() throws {
    let portalContent = NSView()
    let panel = LiveCamPanel(
        frame: CGRect(x: 0, y: 0, width: 200, height: 120),
        contentView: portalContent,
        apertureMask: LiveCamApertureMask { bounds in
            CGPath(
                rect: CGRect(
                    x: bounds.midX - 40,
                    y: bounds.midY - 30,
                    width: 80,
                    height: 60
                ),
                transform: nil
            )
        }
    )

    let apertureView = try #require(panel.contentView)
    apertureView.layoutSubtreeIfNeeded()
    let shapeMask = try #require(
        apertureView.layer?.mask as? CAShapeLayer
    )

    #expect(shapeMask.path?.contains(CGPoint(x: 100, y: 60)) == true)
    #expect(shapeMask.path?.contains(CGPoint(x: 10, y: 10)) == false)
}

@Test
@MainActor
func liveCamPanelOnlyHitsContentInsideTheAperture() throws {
    let portalContent = NSView()
    let panel = LiveCamPanel(
        frame: CGRect(x: 0, y: 0, width: 200, height: 120),
        contentView: portalContent,
        apertureMask: LiveCamApertureMask { _ in
            CGPath(
                ellipseIn: CGRect(x: 60, y: 20, width: 80, height: 80),
                transform: nil
            )
        }
    )

    let apertureView = try #require(panel.contentView)
    apertureView.layoutSubtreeIfNeeded()

    #expect(apertureView.hitTest(CGPoint(x: 100, y: 60)) === apertureView)
    #expect(apertureView.hitTest(CGPoint(x: 20, y: 20)) == nil)
}

@Test
@MainActor
func liveCamPanelCannotSelectAPhysicalCameraFeed() {
    let panel = LiveCamPanel(
        frame: CGRect(x: 0, y: 0, width: 200, height: 120),
        contentView: NSView()
    )

    #expect(panel.feed == .virtualWorld)
}

@Test
@MainActor
func liveCamPanelForwardsAFullStageRequest() {
    var requests = 0
    let panel = LiveCamPanel(
        frame: CGRect(x: 0, y: 0, width: 200, height: 120),
        contentView: NSView(),
        onOpenFullStage: { requests += 1 }
    )

    panel.requestOpenFullStage()
    panel.requestOpenFullStage()

    #expect(requests == 2)
}

@Test
@MainActor
func liveCamPanelCanReplaceItsFullStageHandler() {
    var originalRequests = 0
    var replacementRequests = 0
    let panel = LiveCamPanel(
        frame: CGRect(x: 0, y: 0, width: 200, height: 120),
        contentView: NSView(),
        onOpenFullStage: { originalRequests += 1 }
    )

    panel.setOpenFullStageHandler { replacementRequests += 1 }
    panel.requestOpenFullStage()

    #expect(originalRequests == 0)
    #expect(replacementRequests == 1)
}

@Test
func liveCamPointerBindingsSeparateWindowMovementFromCameraOrbit() {
    #expect(LiveCamPointerBinding.moveWindow.buttonNumbers == [0])
    #expect(LiveCamPointerBinding.moveWindow.buttonMasks == [0x1])
    #expect(LiveCamPointerBinding.rotateCamera.buttonNumbers == [1, 2])
    #expect(LiveCamPointerBinding.rotateCamera.buttonMasks == [0x2, 0x4])
}

@Test
@MainActor
func liveCamReceivesCameraDragWithoutActivatingItsPanel() throws {
    let panel = LiveCamPanel(
        frame: CGRect(x: 0, y: 0, width: 224, height: 336),
        contentView: NSView()
    )

    let apertureView = try #require(panel.contentView)

    #expect(apertureView.acceptsFirstMouse(for: nil))
}

@Test
@MainActor
func liveCamForwardsExplicitRightAndMiddleMouseDragsToCameraRotation() throws {
    let panel = LiveCamPanel(
        frame: CGRect(x: 100, y: 100, width: 224, height: 336),
        contentView: NSView()
    )
    let apertureView = try #require(panel.contentView)
    var rotations: [CGSize] = []
    panel.setRotateHandler { rotations.append($0) }

    func event(_ type: NSEvent.EventType, _ point: CGPoint, _ button: Int) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    apertureView.rightMouseDown(with: try event(.rightMouseDown, CGPoint(x: 50, y: 80), 1))
    apertureView.rightMouseDragged(with: try event(.rightMouseDragged, CGPoint(x: 68, y: 71), 1))
    apertureView.rightMouseUp(with: try event(.rightMouseUp, CGPoint(x: 68, y: 71), 1))
    apertureView.otherMouseDown(with: try event(.otherMouseDown, CGPoint(x: 80, y: 90), 2))
    apertureView.otherMouseDragged(with: try event(.otherMouseDragged, CGPoint(x: 69, y: 104), 2))
    apertureView.otherMouseUp(with: try event(.otherMouseUp, CGPoint(x: 69, y: 104), 2))

    #expect(rotations == [
        CGSize(width: 18, height: -9),
        CGSize(width: -11, height: 14),
    ])
}

@Test
func liveCamWindowDragUsesStableScreenLocationDeltas() {
    #expect(
        LiveCamWindowPointerDelta.resolve(
            previousScreenLocation: nil,
            currentScreenLocation: CGPoint(x: 320, y: 640)
        ) == .zero
    )
    #expect(
        LiveCamWindowPointerDelta.resolve(
            previousScreenLocation: CGPoint(x: 320, y: 640),
            currentScreenLocation: CGPoint(x: 348, y: 623)
        ) == CGSize(width: 28, height: -17)
    )
}

@Test
func liveCamUsesACompactPortraitFrameAroundTheCharacter() {
    let layout = LiveCamLayout.compactPortrait

    #expect(layout.size == CGSize(width: 224, height: 336))
    #expect(layout.size.width / layout.size.height == 2.0 / 3.0)
    #expect(layout.cornerRadius == 28)
}

@Test
func liveCamUsesNeutralCharacterLightingOutsideTheWarmWorld() {
    #expect(
        PMXAvatarLightingPolicy.resolve(
            renderProfile: .liveCam,
            worldLighting: .warmInterior
        ) == .neutralDesktop
    )
    #expect(
        PMXAvatarLightingPolicy.resolve(
            renderProfile: .fullStage,
            worldLighting: .warmInterior
        ) == .warmInterior
    )
}

@Test
@MainActor
func liveCamChatEntryOpensAKeyboardReadyComposer() {
    let panel = LiveCamPanel(
        frame: CGRect(x: 0, y: 0, width: 224, height: 336),
        contentView: NSView()
    )

    #expect(!panel.canBecomeKey)
    #expect(!panel.interactionView.isComposerVisible)

    panel.interactionView.chatButton.performClick(nil)

    #expect(panel.canBecomeKey)
    #expect(panel.interactionView.isComposerVisible)
}

@Test
@MainActor
func liveCamComposerSendsTrimmedTextAndReturnsToObservation() {
    var messages: [String] = []
    let panel = LiveCamPanel(
        frame: CGRect(x: 0, y: 0, width: 224, height: 336),
        contentView: NSView(),
        onSendMessage: { messages.append($0) }
    )

    panel.interactionView.chatButton.performClick(nil)
    panel.interactionView.messageField.stringValue = "  今晚放点爵士吧  "
    panel.interactionView.sendButton.performClick(nil)

    #expect(messages == ["今晚放点爵士吧"])
    #expect(!panel.interactionView.isComposerVisible)
    #expect(!panel.canBecomeKey)
}

@Test
@MainActor
func liveCamVoiceEntryAndAgentReplyStayInsideThePortal() {
    var voiceRequests = 0
    let panel = LiveCamPanel(
        frame: CGRect(x: 0, y: 0, width: 224, height: 336),
        contentView: NSView(),
        onToggleVoice: { voiceRequests += 1 }
    )

    panel.interactionView.voiceButton.performClick(nil)
    panel.showAgentReply("我找到一张很适合夜晚的唱片。")
    panel.setVoiceState(.connected)

    #expect(voiceRequests == 1)
    #expect(panel.interactionView.replyText == "我找到一张很适合夜晚的唱片。")
    #expect(!panel.interactionView.isReplyHidden)
}

@Test
@MainActor
func liveCamClearsAStaleConnectionStatusAfterVoiceConnects() {
    let panel = LiveCamPanel(
        frame: CGRect(x: 0, y: 0, width: 224, height: 336),
        contentView: NSView()
    )

    panel.showChatStatus("先点麦克风连接 Agent，再发送文字。")
    #expect(!panel.interactionView.isReplyHidden)

    panel.setVoiceState(.connected)

    #expect(panel.interactionView.isReplyHidden)
    #expect(panel.interactionView.replyText.isEmpty)
}
