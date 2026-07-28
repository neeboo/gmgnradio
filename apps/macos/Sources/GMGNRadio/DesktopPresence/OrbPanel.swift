import AppKit

@MainActor
final class OrbPanel: NSPanel {
    private(set) var interactionEnabled = false

    init(frame: CGRect, contentView: NSView) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.contentView = contentView
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool {
        interactionEnabled
    }

    override var canBecomeMain: Bool {
        false
    }

    func setInteractionEnabled(_ isEnabled: Bool) {
        guard interactionEnabled != isEnabled else {
            return
        }
        interactionEnabled = isEnabled
        ignoresMouseEvents = !isEnabled
    }
}

