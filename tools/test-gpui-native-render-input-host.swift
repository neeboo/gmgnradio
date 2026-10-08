import Foundation

// Executes the actual production host against private CPU/AppKit leaf doubles.
// No NSWindow, application launch, renderer device, audio or user state is used.
let source = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift", encoding: .utf8)
let start = source.range(of: "@MainActor\nprivate final class GPUIStageRenderInputHost")!.lowerBound
let end = source.range(of: "\n#else\nprivate typealias StageControllerContentView", range: start..<source.endIndex)!.lowerBound
let hostSource = String(source[start..<end])
precondition(!hostSource.contains("NSHostingView") && !hostSource.contains("StageContentView("))
let harness = #"""
import AppKit
enum StageWindowMode { case fullScreen, windowed }
enum LocalMusicPlaybackState { case idle }
enum RealtimeVoiceConnectionState { case idle }
final class VisualAudioFeatureStore {}
final class StageArtworkStore {}
final class StageVisualDirectionStore {}
final class StageVideoPlaybackStore {}
@MainActor final class ResidentPropEditorState {
    var isOpen = false
    var onSceneFocusRequested: (@MainActor (String) -> Void)?
    func open() { isOpen = true }
    func close() { isOpen = false }
}
@MainActor final class SpatialStageStore {
    var isWorldPresentationRequested = true
    var isWorldVisible = true
    var observers: [UUID: (Bool) -> Void] = [:]
    func observeWorldVisibility(_ callback: @escaping (Bool) -> Void) -> UUID {
        let id = UUID(); observers[id] = callback; callback(isWorldVisible); return id
    }
    func removeWorldVisibilityObserver(_ id: UUID?) { if let id { observers[id] = nil } }
    func fire() { for callback in Array(observers.values) { callback(isWorldVisible) } }
}
enum Owner { case detached, fullStage, gpuiFullStage, gpuiLiveCam }
@MainActor final class StageRenderSurfaceController {
    var owner = Owner.detached
    var attaches = 0
    var visible = false
    func attachToFullStage(_ view: NSView) { owner = .fullStage; attaches += 1 }
    func setWorldPresentationVisible(_ value: Bool) { visible = value }
}
struct StageSurfacePresentationState {
    let isSpatialWorldHidden: Bool
    let isPointCloudHidden: Bool
    let isWorldInteractionHidden: Bool
    static func resolve(isWorldPresentationRequested requested: Bool, isWorldVisible visible: Bool) -> Self {
        Self(isSpatialWorldHidden: !visible, isPointCloudHidden: requested, isWorldInteractionHidden: !visible)
    }
}
final class StageRenderSurfaceHostingView: NSView {}
final class WorldScreenOverlayContainer: NSView {}
@MainActor final class StageWorldInteractionView: NSView {
    var onGridCursor: ((SIMD2<Float>) -> Void)?
    var onGridCommit: ((SIMD2<Float>) -> Void)?
    var onGridRotate: ((Int) -> Void)?
    var onScenePick: ((SIMD2<Float>, Int) -> Void)?
    var isTextInputFocused: (() -> Bool)?
    var picks = 0
    init(spatialStage: SpatialStageStore, propEditor: ResidentPropEditorState) { super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    func noteResidentPropScenePickUp() { picks += 1 }
}
@MainActor final class MetalStageView: NSView {
    init(frame: NSRect, audioFeatures: VisualAudioFeatureStore, artwork: StageArtworkStore,
         visualDirections: StageVisualDirectionStore, videos: StageVideoPlaybackStore,
         spatialStage: SpatialStageStore) { super.init(frame: frame) }
    required init?(coder: NSCoder) { nil }
}
"""# + "\n" + hostSource + #"""

@MainActor func check() {
    let spatial = SpatialStageStore(), renderer = StageRenderSurfaceController(), editor = ResidentPropEditorState()
    let host = GPUIStageRenderInputHost(frame: NSRect(x: 0, y: 0, width: 1180, height: 760),
        audioFeatures: VisualAudioFeatureStore(), artwork: StageArtworkStore(),
        visualDirections: StageVisualDirectionStore(), videos: StageVideoPlaybackStore(),
        spatialStage: spatial, renderSurfaceController: renderer, residentPropEditor: editor)
    precondition(host.subviews.count == 4, "GPUI host must construct only native leaves")
    let player = host.subviews.first { $0 is MetalStageView }!
    let playerID = ObjectIdentifier(player)
    let pointer = host.subviews.first { $0 is StageWorldInteractionView } as! StageWorldInteractionView
    var rotations = 0
    host.onGridRotate = { rotations += $0 }; pointer.onGridRotate?(2)
    precondition(rotations == 2)
    host.noteScenePickUp(); precondition(pointer.picks == 1)
    let originalScreen = host.screenOverlayHostView
    for _ in 0..<8 {
        autoreleasepool {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
            renderer.owner = .gpuiFullStage
            host.attachGPUIWorldInteraction(to: container)
            precondition(pointer.superview === container && originalScreen.superview === container)
            precondition(container.subviews.last === originalScreen, "Web screen leaf must remain above pointer leaf")
            let before = renderer.attaches; spatial.fire(); precondition(renderer.attaches == before)
            precondition(host.attachGPUIPlayerSurface(to: container))
            precondition(player.superview === container && ObjectIdentifier(player) == playerID)
            precondition(player.frame == container.bounds)
            host.restoreNativeWorldInteraction()
            precondition(player.superview === host && pointer.superview === host && originalScreen.superview === host)
        }
    }
    let replacement = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 450))
    precondition(host.attachGPUIPlayerSurface(to: replacement))
    precondition(ObjectIdentifier(player) == playerID && player.frame == replacement.bounds)
    replacement.setFrameSize(NSSize(width: 2048, height: 1152))
    precondition(player.frame == replacement.bounds, "native leaf must track viewport resize")
    editor.open(); spatial.isWorldPresentationRequested = false; spatial.isWorldVisible = false; spatial.fire()
    precondition(!editor.isOpen && !renderer.visible)
    precondition(spatial.observers.count == 1)
    print("PASS: production GPUI host, four native leaves, callback forwarding, eight mount/restore cycles, same player, resize, screen ordering and visibility; no window/device")
}
MainActor.assumeIsolated { check() }
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-gpui-native-host-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("fixture.swift")
try harness.write(to: file, atomically: true, encoding: .utf8)
let child = Process()
child.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
child.arguments = [file.path]
try child.run(); child.waitUntilExit()
exit(child.terminationStatus)
