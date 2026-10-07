import AppKit

/// The human composer is the only destination. Payload validation, local copies
/// and preparation remain owned by the existing attachment store.
@MainActor
final class UnityChatImageDropBridge {
    static let shared = UnityChatImageDropBridge()
    private let windowProvider: @MainActor () -> NSWindow?
    private var fileURLs: (([URL]) -> Void)?
    private var bitmap: ((Data) -> Void)?
    private var region: CGRect = .zero
    private var observers: [NSObjectProtocol] = []
    private weak var attachedContent: NSView?
    private weak var attachedWindow: NSWindow?
    private(set) var destination: ResidentImageDropView?

    init(window: @escaping @MainActor () -> NSWindow? = { UnityWindowModeBridge.shared.targetWindow }) {
        windowProvider = window
    }

    func configure(onFileURLs: @escaping ([URL]) -> Void, onBitmap: @escaping (Data) -> Void) {
        fileURLs = onFileURLs; bitmap = onBitmap
        ResidentImageDropMouseWatch.start()
        if observers.isEmpty {
            for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
                let windowID = (note.object as? NSWindow).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, let windowID, let window = self.attachedWindow, windowID == ObjectIdentifier(window) else { return }
                    self.region = .zero; self.detach()
                }
            })
        }
        refresh()
    }

    /// Unity reports the visible input rectangle relative to its whole UI panel,
    /// with top-down Y. All-zero means the chat is hidden, not an invisible target.
    func setRegion(x: Float, yDown: Float, width: Float, height: Float) {
        let values = [x, yDown, width, height]
        guard values.allSatisfy({ $0.isFinite }), x >= 0, yDown >= 0,
              width > 0, height > 0, x + width <= 1.0001, yDown + height <= 1.0001 else {
            region = .zero; detach(); return
        }
        region = CGRect(x: CGFloat(x), y: CGFloat(yDown), width: CGFloat(width), height: CGFloat(height))
        refresh()
    }

    func refresh() {
        guard fileURLs != nil, bitmap != nil, !region.isEmpty,
              let window = windowProvider(), let content = window.contentView,
              content.bounds.width > 0, content.bounds.height > 0 else { detach(); return }
        if attachedContent !== content {
            detach()
            let view = ResidentImageDropView()
            view.registerForDraggedTypes(ResidentImageDropPolicy.registeredTypes)
            view.onFileURLs = { [weak self] urls in self?.fileURLs?(urls) }
            view.onBitmap = { [weak self] data in self?.bitmap?(data) }
            view.wantsLayer = true
            view.layer?.cornerRadius = 8
            view.onTargetingChange = { [weak view] targeted in
                view?.layer?.borderWidth = targeted ? 1 : 0
                view?.layer?.borderColor = NSColor(calibratedRed: 0.22, green: 0.8, blue: 0.9, alpha: 0.8).cgColor
                view?.layer?.backgroundColor = targeted ? NSColor(calibratedRed: 0.22, green: 0.8, blue: 0.9, alpha: 0.1).cgColor : NSColor.clear.cgColor
            }
            content.addSubview(view, positioned: .above, relativeTo: nil)
            destination = view; attachedContent = content; attachedWindow = window
        }
        let bounds = content.bounds
        destination?.frame = CGRect(x: bounds.minX + region.minX * bounds.width,
            y: bounds.minY + (content.isFlipped ? region.minY : 1 - region.maxY) * bounds.height,
            width: region.width * bounds.width, height: region.height * bounds.height)
    }

    func close() {
        region = .zero; fileURLs = nil; bitmap = nil; detach()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func detach() {
        destination?.unregisterDraggedTypes(); destination?.removeFromSuperview()
        destination = nil; attachedContent = nil; attachedWindow = nil
    }
}

@_cdecl("gmgn_unity_chat_image_drop_region")
public func gmgnUnityChatImageDropRegion(_ x: Float, _ yDown: Float, _ width: Float, _ height: Float) {
    guard Thread.isMainThread else { return }
    MainActor.assumeIsolated { UnityChatImageDropBridge.shared.setRegion(x: x, yDown: yDown, width: width, height: height) }
}
