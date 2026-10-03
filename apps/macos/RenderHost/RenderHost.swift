import AppKit
import Foundation

// The application declares this identity beside its @main entry. The isolated
// library deliberately excludes that bootstrap file and uses its own identity.
enum ProductIdentity {
    static let displayName = "GPUI Render Host Probe"
    static let bundleIdentifier = "ai.gmgn.gpui-probe.render-host"
}

/// Probe-only ownership boundary. No App bootstrap, singleton avatar store,
/// standard defaults, credential lookup, microphone or installed App access.
@MainActor
private final class GPUIRenderHost {
    let controller: StageRenderSurfaceController
    let defaults: UserDefaults
    let dataRoot: URL

    init(dataRoot: URL, defaults: UserDefaults) {
        self.dataRoot = dataRoot
        self.defaults = defaults
        let stage = SpatialStageStore(defaults: defaults)
        // A local selection prevents catalog prewarming/network downloads.
        stage.selectWorld(id: LivingPodScene.worldID)
        stage.requestWorldPresentation()
        let library = MarbleWorldLibrary(
            cache: MarbleWorldCache(rootURL: dataRoot.appendingPathComponent("cache/marble")),
            spatialStage: stage
        )
        let avatar = StageAvatarRuntimeStore(
            packageStore: PresencePackageStore(rootURL: dataRoot.appendingPathComponent("avatars")),
            motionPackageStore: MotionPackageStore(rootURL: dataRoot.appendingPathComponent("motions"))
        )
        controller = StageRenderSurfaceController(
            spatialStage: stage, library: library, avatarRuntime: avatar
        )
    }
}

// Every entry point must run on the AppKit main thread. Wrong-thread calls
// return failure; they do not synchronously dispatch and risk deadlock.
@_cdecl("gmgn_render_host_create")
func gmgnRenderHostCreate(_ root: UnsafePointer<CChar>?, _ suite: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread, let root, let suite else { return nil }
    let path = String(cString: root)
    let name = String(cString: suite)
    guard path.hasPrefix("/"), path != "/", name.hasPrefix("ai.gmgn.gpui-probe."),
          let defaults = UserDefaults(suiteName: name) else { return nil }
    let address = MainActor.assumeIsolated {
        UInt(bitPattern: Unmanaged.passRetained(GPUIRenderHost(dataRoot: URL(fileURLWithPath: path), defaults: defaults)).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: address)
}

@_cdecl("gmgn_render_host_attach")
func gmgnRenderHostAttach(_ handle: UnsafeMutableRawPointer?, _ container: UnsafeMutableRawPointer?, _ fullStage: Int32) -> Int32 {
    guard Thread.isMainThread, let handle, let container else { return 0 }
    let handleAddress = UInt(bitPattern: handle)
    let containerAddress = UInt(bitPattern: container)
    return MainActor.assumeIsolated {
        let handle = UnsafeMutableRawPointer(bitPattern: handleAddress)!
        let container = UnsafeMutableRawPointer(bitPattern: containerAddress)!
        let host = Unmanaged<GPUIRenderHost>.fromOpaque(handle).takeUnretainedValue()
        let view = Unmanaged<NSView>.fromOpaque(container).takeUnretainedValue()
        if fullStage != 0 { host.controller.attachToFullStage(view) }
        else { host.controller.attachToLiveCam(view) }
        return 1
    }
}

@_cdecl("gmgn_render_host_view")
func gmgnRenderHostView(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread, let handle else { return nil }
    let handleAddress = UInt(bitPattern: handle)
    let address = MainActor.assumeIsolated {
        let handle = UnsafeMutableRawPointer(bitPattern: handleAddress)!
        return UInt(bitPattern: Unmanaged.passUnretained(Unmanaged<GPUIRenderHost>.fromOpaque(handle).takeUnretainedValue().controller.surfaceView).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: address)
}

@_cdecl("gmgn_render_host_visibility")
func gmgnRenderHostVisibility(_ handle: UnsafeMutableRawPointer?, _ visible: Int32, _ occluded: Int32) -> Int32 {
    guard Thread.isMainThread, let handle else { return 0 }
    let handleAddress = UInt(bitPattern: handle)
    return MainActor.assumeIsolated {
        let handle = UnsafeMutableRawPointer(bitPattern: handleAddress)!
        let controller = Unmanaged<GPUIRenderHost>.fromOpaque(handle).takeUnretainedValue().controller
        controller.setOwnerVisibility(visible != 0, occluded: occluded != 0, owner: controller.owner)
        return 1
    }
}

@_cdecl("gmgn_render_host_rotate")
func gmgnRenderHostRotate(_ handle: UnsafeMutableRawPointer?, _ yaw: Float, _ pitch: Float) -> Int32 {
    guard Thread.isMainThread, let handle, yaw.isFinite, pitch.isFinite else { return 0 }
    let handleAddress = UInt(bitPattern: handle)
    return MainActor.assumeIsolated {
        let handle = UnsafeMutableRawPointer(bitPattern: handleAddress)!
        Unmanaged<GPUIRenderHost>.fromOpaque(handle).takeUnretainedValue().controller.rotateLiveCam(deltaYaw: yaw, deltaPitch: pitch)
        return 1
    }
}

@_cdecl("gmgn_render_host_diagnostics")
func gmgnRenderHostDiagnostics(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
    guard Thread.isMainThread, let handle else { return nil }
    let handleAddress = UInt(bitPattern: handle)
    let address: UInt? = MainActor.assumeIsolated {
        let handle = UnsafeMutableRawPointer(bitPattern: handleAddress)!
        let controller = Unmanaged<GPUIRenderHost>.fromOpaque(handle).takeUnretainedValue().controller
        let value: [String: Any] = [
            "owner": String(describing: controller.owner),
            "surfaceClass": String(describing: type(of: controller.surfaceView)),
            "attached": controller.surfaceView.superview != nil,
            "hasWindow": controller.surfaceView.window != nil,
            "drawableWidth": controller.surfaceView.drawableSize.width,
            "drawableHeight": controller.surfaceView.drawableSize.height,
            "scheduling": controller.renderSchedulingDiagnostics,
            "performance": controller.surfaceView.renderPerformanceDiagnostics,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return strdup(string).map { UInt(bitPattern: $0) }
    }
    return address.flatMap { UnsafeMutablePointer<CChar>(bitPattern: $0) }
}

@_cdecl("gmgn_render_host_string_free")
func gmgnRenderHostStringFree(_ string: UnsafeMutablePointer<CChar>?) { free(string) }

@_cdecl("gmgn_render_host_destroy")
func gmgnRenderHostDestroy(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard Thread.isMainThread, let handle else { return 0 }
    let handleAddress = UInt(bitPattern: handle)
    return MainActor.assumeIsolated {
        let handle = UnsafeMutableRawPointer(bitPattern: handleAddress)!
        let host = Unmanaged<GPUIRenderHost>.fromOpaque(handle).takeRetainedValue()
        host.controller.detach(from: host.controller.owner)
        return 1
    }
}
