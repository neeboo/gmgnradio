import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PropGenerationError: Error { case invalidInput }

@MainActor final class ImageDropContent: NSView {
    var usesFlippedCoordinates = false
    override var isFlipped: Bool { usesFlippedCoordinates }
}
@MainActor final class ImageDropWindowReference {
    weak var window: NSWindow?
    init(_ window: NSWindow) { self.window = window }
}

/// A real AppKit dragging destination receives an actual private pasteboard;
/// only the OS drag-session wrapper is supplied by this deterministic fixture.
@MainActor final class ImageDragInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(_ pasteboard: NSPasteboard, window: NSWindow) { draggingPasteboard = pasteboard; draggingDestinationWindow = window }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@main struct UnityChatImageDropChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-drop-check-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 450), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Never order the fixture window front or activate it while the user tests.
        let content = ImageDropContent(frame: .init(x: 0, y: 0, width: 720, height: 450))
        window.contentView = content
        let sceneInput = NSView(frame: content.bounds); sceneInput.autoresizingMask = [.width, .height]; content.addSubview(sceneInput)
        let target = ImageDropWindowReference(window)
        let drop = UnityChatImageDropBridge(window: { target.window })
        let images = UnityChatImageBridge(directory: directory.appendingPathComponent("draft"), parentWindow: { window })
        var fileCalls = 0, bitmapCalls = 0
        drop.configure(onFileURLs: { urls in fileCalls += 1; _ = images.addDroppedImages(urls: urls) },
                       onBitmap: { bytes in bitmapCalls += 1; _ = images.addDroppedImage(data: bytes) })
        defer { drop.close(); images.close(); window.close() }
        drop.setRegion(x: 0.1, yDown: 0.2, width: 0.5, height: 0.25)
        let view = try requireDestination(drop)
        precondition(view.superview === content && view.registeredDraggedTypes.contains(.fileURL))
        precondition(!view.acceptsFirstResponder)
        try checkFrame(view.frame, .init(x: 72, y: 247.5, width: 360, height: 112.5))
        precondition(view.hitTest(view.frame.origin) == nil, "Ordinary pointer events must not hit native overlay")
        precondition(content.hitTest(view.frame.center) === sceneInput, "Unity camera/furniture/text view remains the normal mouse target")
        for event in [NSEvent.EventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .mouseMoved, .scrollWheel, .keyDown] {
            precondition(!ResidentImageDropPolicy.allowsHitTesting(eventType: event, localMouseIsDown: false))
        }
        for event in [NSEvent.EventType.leftMouseDragged, .rightMouseDragged, .otherMouseDragged] {
            precondition(!ResidentImageDropPolicy.allowsHitTesting(eventType: event, localMouseIsDown: true), "App-owned camera, furniture or text drags stay transparent")
            precondition(ResidentImageDropPolicy.allowsHitTesting(eventType: event, localMouseIsDown: false), "External pointer drag can reach destination")
        }
        content.usesFlippedCoordinates = true; drop.refresh()
        try checkFrame(view.frame, .init(x: 72, y: 90, width: 360, height: 112.5))
        window.setContentSize(.init(width: 1280, height: 720))
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        try checkFrame(try requireDestination(drop).frame, .init(x: 128, y: 144, width: 640, height: 180))
        content.bounds.origin = .init(x: 13, y: 17); drop.refresh()
        try checkFrame(try requireDestination(drop).frame, .init(x: 141, y: 161, width: 640, height: 180))
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        try checkFrame(try requireDestination(drop).frame, .init(x: 141, y: 161, width: 640, height: 180))

        let source = directory.appendingPathComponent("human-original.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 24, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let encoded = NSMutableData()
        let writer = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, bitmap.cgImage!, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private metadata", kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.345, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 67.89, kCGImagePropertyGPSLongitudeRef: "E"]
        ] as CFDictionary)
        precondition(CGImageDestinationFinalize(writer))
        let originalProperties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(encoded, nil)!, 0, nil)! as NSDictionary
        let originalEXIF = originalProperties[kCGImagePropertyExifDictionary] as! NSDictionary
        let originalGPS = originalProperties[kCGImagePropertyGPSDictionary] as! NSDictionary
        precondition(originalEXIF[kCGImagePropertyExifUserComment] as? String == "private metadata" && originalEXIF[kCGImagePropertyExifDateTimeOriginal] != nil && originalGPS[kCGImagePropertyGPSLatitude] != nil,
                     "The fixture must actually encode all private source metadata before asserting stripping")
        try (encoded as Data).write(to: source)
        let board = NSPasteboard(name: .init("gmgn-drop-payload-\(UUID())"))
        defer { board.releaseGlobally() }
        let sender = ImageDragInfo(board, window: window)
        board.clearContents(); board.setString("普通文字 /tmp/human-original.png", forType: .string)
        precondition(view.draggingEntered(sender).isEmpty && !view.prepareForDragOperation(sender) && !view.performDragOperation(sender))
        precondition(fileCalls == 0 && bitmapCalls == 0 && images.snapshot()["count"] as! Int == 0)
        board.clearContents(); board.writeObjects([source as NSURL])
        precondition(view.draggingEntered(sender) == .copy && view.prepareForDragOperation(sender))
        precondition(view.performDragOperation(sender)); view.concludeDragOperation(sender)
        try await ready(images)
        precondition(fileCalls == 1 && bitmapCalls == 0 && images.snapshot()["count"] as! Int == 1)
        try checkPreparedImage(images)
        board.clearContents(); board.setData(encoded as Data, forType: .png)
        precondition(view.draggingUpdated(sender) == .copy && view.performDragOperation(sender))
        try await ready(images)
        precondition(fileCalls == 1 && bitmapCalls == 1 && images.snapshot()["count"] as! Int == 2)
        for _ in 0..<2 { precondition(view.performDragOperation(sender)); try await ready(images) }
        precondition(images.snapshot()["count"] as! Int == 4)
        _ = view.performDragOperation(sender)
        precondition(images.snapshot()["count"] as! Int == 4 && images.snapshot()["error"] as? String == "每条消息最多添加 4 张图片。")
        precondition(FileManager.default.fileExists(atPath: source.path), "User's original is retained")

        drop.setRegion(x: 0, yDown: 0, width: 0, height: 0)
        precondition(drop.destination == nil && view.superview == nil && view.registeredDraggedTypes.isEmpty)
        drop.setRegion(x: .nan, yDown: 0, width: 0.2, height: 0.2); precondition(drop.destination == nil)
        drop.setRegion(x: 0.9, yDown: 0, width: 0.2, height: 0.2); precondition(drop.destination == nil)
        drop.setRegion(x: 0.1, yDown: 0.2, width: 0.5, height: 0.25); precondition(drop.destination != nil)
        target.window = nil; drop.refresh(); precondition(drop.destination == nil)
        target.window = window; drop.refresh(); precondition(drop.destination != nil)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        precondition(drop.destination == nil)
        gmgnUnityChatImageDropRegion(0, 0, 0, 0) // exact exported four-float ABI
        print("PASS: real AppKit destination, image URL/bitmap payloads into private prepared drafts, <=2048px/EXIF stripping/four cap; transparent normal/local drag input, flipped/resize/fullscreen coordinates, hidden/invalid/close removal; no automatic send")
    }
    @MainActor static func requireDestination(_ bridge: UnityChatImageDropBridge) throws -> ResidentImageDropView {
        guard let view = bridge.destination else { throw NSError(domain: "DropChecks", code: 1) }; return view
    }
    static func checkFrame(_ actual: CGRect, _ expected: CGRect) throws {
        guard abs(actual.minX - expected.minX) < 0.01, abs(actual.minY - expected.minY) < 0.01,
              abs(actual.width - expected.width) < 0.01, abs(actual.height - expected.height) < 0.01 else {
            throw NSError(domain: "DropChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Wrong AppKit drop frame: \(actual) expected \(expected)"])
        }
    }
    @MainActor static func ready(_ bridge: UnityChatImageBridge) async throws {
        let deadline = Date().addingTimeInterval(8)
        while bridge.snapshot()["isPreparing"] as! Bool {
            guard Date() < deadline else { throw NSError(domain: "DropChecks", code: 3) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor static func checkPreparedImage(_ bridge: UnityChatImageBridge) throws {
        let snapshot = bridge.snapshot(), objects = snapshot["attachments"] as! [[String: String]]
        let generation = snapshot["generation"] as! UInt64
        let submission = try bridge.takeSubmission(text: "", attachmentIDs: objects.map { $0["id"]! }, generation: generation)
        let image = submission.attachments[0]
        let properties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(image.url as CFURL, nil)!, 0, nil)! as NSDictionary
        precondition((properties[kCGImagePropertyPixelWidth] as! NSNumber).intValue <= 2048)
        // ImageIO can synthesize pixel-dimension/color-space EXIF keys during
        // encoding. The source's private EXIF payload must not be retained.
        let exif = properties[kCGImagePropertyExifDictionary] as? NSDictionary
        precondition(exif?[kCGImagePropertyExifUserComment] == nil && exif?[kCGImagePropertyExifDateTimeOriginal] == nil && properties[kCGImagePropertyGPSDictionary] == nil)
        let data = try Data(contentsOf: image.url)
        precondition(data.count <= 8 * 1024 * 1024)
        precondition(bridge.restoreSubmission(submission), "Inspection restores only its own issued draft; no chat.send")
    }
}

private extension CGRect { var center: CGPoint { .init(x: midX, y: midY) } }
