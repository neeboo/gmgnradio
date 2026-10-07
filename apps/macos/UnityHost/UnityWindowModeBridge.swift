import AppKit
import QuartzCore

/// Changes the existing Unity window; never opens a disconnected second player.
@MainActor
final class UnityWindowModeBridge {
    static let shared = UnityWindowModeBridge()
    private weak var window: NSWindow?
    private var normalFrame: NSRect?
    private var normalMinSize: NSSize = .zero
    private var normalMaxSize: NSSize = .zero
    private var normalLevel: NSWindow.Level = .normal
    private var normalBehavior: NSWindow.CollectionBehavior = []
    private var normalStyle: NSWindow.StyleMask = []
    private var normalBackground = NSColor.windowBackgroundColor
    private var normalOpaque = true
    private var normalShadow = true
    private var normalMovable = false
    private var normalWantsLayer = false
    private var normalCornerRadius: CGFloat = 0
    private var normalMasksToBounds = false
    private var layerOpacity: [(CALayer, Bool, CGColor?)] = []
    var defaults: UserDefaults = UserDefaults(suiteName: "ai.gmgn.radio") ?? .standard
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var dragActive = false
    private var dragMouseOrigin = CGPoint.zero
    private var dragWindowOrigin = CGPoint.zero
    private var nativePointerDown = false
    private var pendingPassiveClick = false
    private var interactiveRegions: [CGRect] = []
    private var normalFrameObservers: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?
    private static let normalFrameKey = "unity.normalWindow.frame.v1"
    private var changingWindowMode = false
    private var fullscreenTransition = false
    private var lastSavedNormalFrame: String?
    private(set) var isCompact = false

    var targetWindow: NSWindow? {
        let target = window ?? NSApp.windows.first(where: {
            $0.isVisible && !$0.isKind(of: NSPanel.self)
                && String(describing: type(of: $0)).contains("Unity")
        }) ?? NSApp.windows.first(where: {
            $0.isVisible && !$0.isKind(of: NSPanel.self) && $0.title.localizedCaseInsensitiveContains("gmgn")
        })
        if let target { prepareNormalWindow(target) }
        return target
    }

    /// Unity remembers its last windowed resolution even when that resolution
    /// belonged to LiveCam. Repair only those known compact sizes, preserving an
    /// ordinary user's valid window size and the last genuine normal frame.
    private func prepareNormalWindow(_ target: NSWindow) {
        guard !isCompact else { return }
        let firstAttachment = observedWindow !== target
        if firstAttachment {
            for observer in normalFrameObservers { NotificationCenter.default.removeObserver(observer) }
            normalFrameObservers.removeAll()
            observedWindow = target
            for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
                         NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                let observer = NotificationCenter.default.addObserver(forName: name, object: target, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.fullscreenTransition = name == NSWindow.willEnterFullScreenNotification
                            || name == NSWindow.willExitFullScreenNotification
                    }
                }
                normalFrameObservers.append(observer)
            }
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                let observer = NotificationCenter.default.addObserver(forName: name, object: target, queue: .main) { [weak self, weak target] _ in
                    MainActor.assumeIsolated {
                        if let target, let self {
                            guard !self.changingWindowMode else { return }
                            if self.isCompact && name == NSWindow.didResizeNotification {
                                self.applyTransparentSurface(target.contentView)
                            } else {
                                self.saveNormalFrame(target)
                            }
                        }
                    }
                }
                normalFrameObservers.append(observer)
            }
            // Our stored rectangle is an AppKit frame, including the title bar.
            // Unity's saved resolution is a content size; never round-trip that
            // content height into the frame preference on every launch.
            if !target.styleMask.contains(.fullScreen), let text = defaults.string(forKey: Self.normalFrameKey) {
                let saved = NSRectFromString(text)
                let savedContent = target.contentRect(forFrameRect: saved)
                if saved.origin.x.isFinite, saved.origin.y.isFinite,
                   savedContent.width.isFinite, savedContent.height.isFinite,
                   savedContent.width >= 720, savedContent.height >= 450 {
                    target.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                    target.setFrame(saved, display: true)
                }
            }
        }
        guard !fullscreenTransition, !target.styleMask.contains(.fullScreen) else { return }
        let content = target.contentRect(forFrameRect: target.frame)
        // A previously titled build may have persisted the frame height while
        // Unity restores it as content height (or vice versa).
        let inheritedCompact = (abs(content.width - 320) <= 4 && (440...510).contains(content.height))
            || (abs(content.width - 224) <= 4 && (300...370).contains(content.height))
        if inheritedCompact {
            var frame: NSRect?
            if let text = defaults.string(forKey: Self.normalFrameKey) {
                let saved = NSRectFromString(text)
                let savedContent = target.contentRect(forFrameRect: saved)
                if saved.origin.x.isFinite, saved.origin.y.isFinite,
                   savedContent.width.isFinite, savedContent.height.isFinite,
                   savedContent.width >= 720, savedContent.height >= 450 { frame = saved }
            }
            if frame == nil {
                let visible = (target.screen ?? NSScreen.main)?.visibleFrame ?? target.frame
                let size = NSSize(width: min(1024, visible.width - 32), height: min(720, visible.height - 32))
                var normal = target.frameRect(forContentRect: NSRect(origin: .zero, size: size))
                normal.origin = NSPoint(x: visible.midX - normal.width / 2, y: visible.midY - normal.height / 2)
                frame = normal
            }
            // Old builds constrained both min and max to the compact rectangle.
            target.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            target.contentMinSize = NSSize(width: 720, height: 450)
            if let frame { target.setFrame(frame, display: true) }
        } else {
            target.contentMinSize = NSSize(width: max(target.contentMinSize.width, 720),
                                           height: max(target.contentMinSize.height, 450))
        }
        saveNormalFrame(target)
    }

    private func saveNormalFrame(_ target: NSWindow) {
        guard !isCompact, !changingWindowMode, !fullscreenTransition, !target.styleMask.contains(.fullScreen) else { return }
        let content = target.contentRect(forFrameRect: target.frame)
        guard content.width >= 720, content.height >= 450 else { return }
        let frame = NSStringFromRect(target.frame)
        guard frame != lastSavedNormalFrame else { return }
        defaults.set(frame, forKey: Self.normalFrameKey)
        lastSavedNormalFrame = frame
    }

    func setCompact(_ compact: Bool) -> Bool {
        guard let target = targetWindow else { return false }
        // Unity must leave full screen before its normal frame can be saved.
        guard !fullscreenTransition, !target.styleMask.contains(.fullScreen) else { return false }
        guard compact != isCompact else { return true }
        // Removing/restoring the title bar emits intermediate resize events.
        // They must not overwrite the saved normal frame or its layer opacity.
        changingWindowMode = true
        defer {
            changingWindowMode = false
            if !isCompact { saveNormalFrame(target) }
        }
        window = target
        if compact {
            saveNormalFrame(target)
            normalFrame = target.frame
            normalMinSize = target.minSize
            normalMaxSize = target.maxSize
            normalLevel = target.level
            normalBehavior = target.collectionBehavior
            normalStyle = target.styleMask
            normalBackground = target.backgroundColor
            normalOpaque = target.isOpaque
            normalShadow = target.hasShadow
            normalMovable = target.isMovableByWindowBackground
            normalWantsLayer = target.contentView?.wantsLayer ?? false
            normalCornerRadius = target.contentView?.layer?.cornerRadius ?? 0
            normalMasksToBounds = target.contentView?.layer?.masksToBounds ?? false
            target.styleMask = [.borderless]
            target.backgroundColor = .clear
            target.isOpaque = false
            target.hasShadow = false
            target.isMovableByWindowBackground = false
            target.contentView?.wantsLayer = true
            layerOpacity.removeAll()
            if let layer = target.contentView?.layer {
                layer.cornerRadius = 28
                layer.masksToBounds = true
            }
            applyTransparentSurface(target.contentView)
            let content = NSRect(x: 0, y: 0, width: 224, height: 336)
            var frame = target.frameRect(forContentRect: content)
            let visible = (target.screen ?? NSScreen.main)?.visibleFrame ?? target.frame
            frame.origin = NSPoint(x: visible.maxX - frame.width - 16,
                                   y: visible.minY + 16)
            if defaults.object(forKey: "liveCam.origin.x") != nil,
               defaults.object(forKey: "liveCam.origin.y") != nil {
                frame = WindowPlacement.restoredFrame(
                    size: frame.size,
                    displays: NSScreen.screens.map {
                        DisplayFrame(id: Self.screenID($0), visibleFrame: $0.visibleFrame)
                    },
                    savedDisplayID: defaults.string(forKey: "liveCam.displayID"),
                    savedOrigin: CGPoint(x: defaults.double(forKey: "liveCam.origin.x"),
                                         y: defaults.double(forKey: "liveCam.origin.y")),
                    margin: 16)
            }
            target.minSize = frame.size
            target.maxSize = frame.size
            target.level = .floating
            target.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            target.setFrame(frame, display: true)
            // Unity can replace its drawable layer while handling the resize.
            // Configure the actual post-resize view hierarchy as well.
            applyTransparentSurface(target.contentView)
            installDragMonitors()
        } else {
            finishDrag()
            removeDragMonitors()
            target.styleMask = normalStyle
            target.backgroundColor = normalBackground
            target.isOpaque = normalOpaque
            target.hasShadow = normalShadow
            target.isMovableByWindowBackground = normalMovable
            for (layer, opaque, background) in layerOpacity {
                layer.isOpaque = opaque
                layer.backgroundColor = background
            }
            layerOpacity.removeAll()
            target.contentView?.layer?.cornerRadius = normalCornerRadius
            target.contentView?.layer?.masksToBounds = normalMasksToBounds
            target.contentView?.wantsLayer = normalWantsLayer
            target.minSize = normalMinSize
            target.maxSize = normalMaxSize
            target.level = normalLevel
            target.collectionBehavior = normalBehavior
            if let frame = normalFrame { target.setFrame(frame, display: true) }
            normalFrame = nil
        }
        isCompact = compact
        NSLog("[LiveCamWindow] compact=%d frame=%@ content=%@ opaque=%d", compact ? 1 : 0,
              NSStringFromRect(target.frame), NSStringFromRect(target.contentView?.bounds ?? .zero), target.isOpaque ? 1 : 0)
        target.makeKeyAndOrderFront(nil)
        logInputFocus(target, reason: compact ? "compact-enter" : "compact-exit")
        return true
    }

    private func logInputFocus(_ target: NSWindow, reason: String, point: NSPoint? = nil) {
        let responder = target.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let hit = point.flatMap { target.contentView?.hitTest($0) }
        NSLog("[LiveCamFocus] reason=%@ class=%@ style=%llu canKey=%d key=%d main=%d appActive=%d responder=%@ hit=%@",
              reason, String(describing: type(of: target)), UInt64(target.styleMask.rawValue),
              target.canBecomeKey ? 1 : 0, target.isKeyWindow ? 1 : 0,
              target.isMainWindow ? 1 : 0, NSApp.isActive ? 1 : 0, responder,
              hit.map { String(describing: type(of: $0)) } ?? "nil")
    }

    func drag(deltaX: Double, deltaY: Double) {
        guard isCompact, let window else { return }
        if !dragActive {
            dragMouseOrigin = NSEvent.mouseLocation
            dragWindowOrigin = CGPoint(x: window.frame.minX + deltaX, y: window.frame.minY + deltaY)
            NSLog("[LiveCamPointer] native drag begin")
        }
        // Window-local Unity input moves when the window moves. The original
        // LiveCam uses global AppKit screen coordinates to avoid that feedback.
        let mouse = NSEvent.mouseLocation
        let origin = CGPoint(x: dragWindowOrigin.x + mouse.x - dragMouseOrigin.x,
                             y: dragWindowOrigin.y + mouse.y - dragMouseOrigin.y)
        window.setFrameOrigin(origin)
        dragActive = true
        saveCompactPosition()
    }

    private func applyTransparentSurface(_ view: NSView?) {
        guard let view else { return }
        func clear(_ layer: CALayer) {
            if !layerOpacity.contains(where: { $0.0 === layer }) {
                layerOpacity.append((layer, layer.isOpaque, layer.backgroundColor))
            }
            layer.isOpaque = false
            layer.backgroundColor = NSColor.clear.cgColor
            for child in layer.sublayers ?? [] { clear(child) }
        }
        if let layer = view.layer { clear(layer) }
        for child in view.subviews { applyTransparentSurface(child) }
    }

    func refreshCompactTransparency() {
        guard isCompact, let window else { return }
        // A pending Unity fullscreen resize can overwrite the first native resize.
        // Enforce the compact contract on the settled window before its drawable.
        if abs(window.frame.width - 224) > 1 || abs(window.frame.height - 336) > 1 {
            var frame = window.frame
            frame.size = NSSize(width: 224, height: 336)
            window.setFrame(frame, display: true)
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        // Unity recreates/configures its Metal surface asynchronously after an
        // AppKit resize and writes opaque=true. Reapply only once the Unity
        // framebuffer has reached the requested compact size.
        applyTransparentSurface(window.contentView)
    }

    private func installDragMonitors() {
        removeDragMonitors()
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handlePointer(event) }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.nativePointerDown = false
                self?.finishDrag()
            }
        }
    }

    private func handlePointer(_ event: NSEvent) {
        guard isCompact, let window, event.window === window else { return }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        switch event.type {
        case .leftMouseDown:
            logInputFocus(window, reason: "left-down", point: event.locationInWindow)
            let height = window.contentView?.bounds.height ?? 336
            let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
            let ownsUI = interactiveRegions.contains { $0.contains(point) }
            nativePointerDown = !ownsUI
            dragActive = false
            dragMouseOrigin = screenPoint
            dragWindowOrigin = window.frame.origin
            NSLog("[LiveCamPointer] native leftDown ui=%@", ownsUI ? "true" : "false")
        case .leftMouseDragged:
            guard nativePointerDown else { return }
            let dx = screenPoint.x - dragMouseOrigin.x
            let dy = screenPoint.y - dragMouseOrigin.y
            if !dragActive, dx * dx + dy * dy > 9 {
                dragActive = true
                NSLog("[LiveCamPointer] native drag begin")
            }
            if dragActive {
                window.setFrameOrigin(CGPoint(x: dragWindowOrigin.x + dx, y: dragWindowOrigin.y + dy))
                saveCompactPosition()
            }
        case .leftMouseUp:
            logInputFocus(window, reason: "left-up", point: event.locationInWindow)
            NSLog("[LiveCamPointer] native leftUp received passive=%@ location=(%.1f,%.1f)",
                  nativePointerDown ? "true" : "false", event.locationInWindow.x, event.locationInWindow.y)
            guard nativePointerDown else { return }
            nativePointerDown = false
            var moved = dragActive
            if moved { finishDrag() }
            else {
                let dx = screenPoint.x - dragMouseOrigin.x
                let dy = screenPoint.y - dragMouseOrigin.y
                // Even a synthesised short gesture that skipped drag events must
                // not be mistaken for the passive click that enters the space.
                if dx * dx + dy * dy > 9 {
                    dragActive = true
                    moved = true
                    window.setFrameOrigin(CGPoint(x: dragWindowOrigin.x + dx, y: dragWindowOrigin.y + dy))
                    finishDrag()
                } else { pendingPassiveClick = true }
            }
            NSLog("[LiveCamPointer] native leftUp moved=%@", moved ? "true" : "false")
        default: break
        }
    }

    func updateInteractiveRegions(_ regions: [CGRect]) { interactiveRegions = regions }
    func takePassiveClick() -> Bool {
        let clicked = pendingPassiveClick
        pendingPassiveClick = false
        return clicked
    }

    private func removeDragMonitors() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        nativePointerDown = false
        pendingPassiveClick = false
    }

    private func finishDrag() {
        guard isCompact, dragActive, let window else { return }
        dragActive = false
        let frame = LiveCamWindowMovementPolicy.frame(
            from: window.frame, translation: .zero, phase: .ended,
            visibleFrames: NSScreen.screens.map(\.visibleFrame), margin: 16, snapDistance: 18)
        window.setFrameOrigin(frame.origin)
        saveCompactPosition()
        NSLog("[LiveCamPointer] native drag end")
    }

    private func saveCompactPosition() {
        guard let window, let screen = window.screen else { return }
        defaults.set(Self.screenID(screen), forKey: "liveCam.displayID")
        defaults.set(window.frame.minX, forKey: "liveCam.origin.x")
        defaults.set(window.frame.minY, forKey: "liveCam.origin.y")
    }

    private static func screenID(_ screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.stringValue ?? String(describing: screen.frame)
    }
}

@_cdecl("gmgn_unity_window_drag_compact")
public func gmgnUnityWindowDragCompact(_ deltaX: Double, _ deltaY: Double) {
    guard deltaX.isFinite, deltaY.isFinite else { return }
    if Thread.isMainThread {
        MainActor.assumeIsolated { UnityWindowModeBridge.shared.drag(deltaX: deltaX, deltaY: deltaY) }
    } else {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { UnityWindowModeBridge.shared.drag(deltaX: deltaX, deltaY: deltaY) }
        }
    }
}

@_cdecl("gmgn_unity_window_set_compact")
public func gmgnUnityWindowSetCompact(_ compact: Int32) -> Int32 {
    if Thread.isMainThread {
        return MainActor.assumeIsolated { UnityWindowModeBridge.shared.setCompact(compact != 0) ? 1 : 0 }
    }
    return DispatchQueue.main.sync {
        MainActor.assumeIsolated { UnityWindowModeBridge.shared.setCompact(compact != 0) ? 1 : 0 }
    }
}

@_cdecl("gmgn_unity_window_compact_regions")
public func gmgnUnityWindowCompactRegions(_ values: UnsafePointer<Double>?, _ count: Int32) {
    guard let values, count >= 0, count <= 256 else { return }
    let regions = (0..<Int(count)).map { index in
        CGRect(x: values[index * 4], y: values[index * 4 + 1],
               width: values[index * 4 + 2], height: values[index * 4 + 3])
    }
    if Thread.isMainThread {
        MainActor.assumeIsolated { UnityWindowModeBridge.shared.updateInteractiveRegions(regions) }
    } else {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { UnityWindowModeBridge.shared.updateInteractiveRegions(regions) }
        }
    }
}

@_cdecl("gmgn_unity_window_take_compact_click")
public func gmgnUnityWindowTakeCompactClick() -> Int32 {
    if Thread.isMainThread {
        return MainActor.assumeIsolated { UnityWindowModeBridge.shared.takePassiveClick() ? 1 : 0 }
    }
    return DispatchQueue.main.sync {
        MainActor.assumeIsolated { UnityWindowModeBridge.shared.takePassiveClick() ? 1 : 0 }
    }
}

@_cdecl("gmgn_unity_window_is_compact")
public func gmgnUnityWindowIsCompact() -> Int32 {
    if Thread.isMainThread {
        return MainActor.assumeIsolated { UnityWindowModeBridge.shared.isCompact ? 1 : 0 }
    }
    return DispatchQueue.main.sync {
        MainActor.assumeIsolated { UnityWindowModeBridge.shared.isCompact ? 1 : 0 }
    }
}

@_cdecl("gmgn_unity_window_refresh_compact_transparency")
public func gmgnUnityWindowRefreshCompactTransparency() {
    if Thread.isMainThread {
        MainActor.assumeIsolated { UnityWindowModeBridge.shared.refreshCompactTransparency() }
    } else {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { UnityWindowModeBridge.shared.refreshCompactTransparency() }
        }
    }
}
