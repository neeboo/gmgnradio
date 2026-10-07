import AppKit
@preconcurrency import AVFoundation
import CoreVideo
import Metal
import WorldRuntime
import simd

/// One decoder/audio owner: original native screen coordinator and stage video store.
/// Exports borrowed Metal textures, not signed media URLs or pixel JSON. Host must
/// destroy the Unity consumers before close. No content starts during construction.
@MainActor final class UnityScreenVideoBridge: WorldScreenControlling {
    static let supportedCommands = ["screen.list", "screen.play", "screen.stop", "video.load", "video.choose", "video.select", "video.remove", "video.play", "video.pause", "video.stop", "video.mode", "video.brightness", "video.bind", "video.unbind", "video.bound.play", "video.bound.dismiss"]
    struct CurrentTrack {
        let id: String
        let title: String
        let cue: ProgramVisualCue
    }
    let videos: StageVideoPlaybackStore
    private let state: () -> WorldState?
    private let names: (String) -> String
    private let currentTrack: () -> CurrentTrack?
    private var followedTrackID: String?
    private let registry = WorldScreenNativeVideoRegistry()
    private let screens: NativeScreenPlaybackCoordinator
    private var operations: [String: Task<Void, Never>] = [:]
    private var screenEpochs: [String: UInt64] = [:]
    private var heldTextures: [String: [MTLTexture]] = [:]
    private var panel: NSOpenPanel?
    private var closed = false
    private var notice = ""
    private var screenCommandNotice = ""
    private var failureDiagnostics = FailureDiagnosticCache()
    private let backgroundFrames: UnityStageVideoFrames

    struct FailureDiagnosticCache {
        private(set) var entries: [String: String] = [:]
        mutating func changed(_ diagnostic: String?, for id: String) -> String? {
            guard let diagnostic else { entries[id] = nil; return nil }
            guard entries[id] != diagnostic else { return nil }
            entries[id] = diagnostic
            return diagnostic
        }
        mutating func retain(_ ids: Set<String>) { entries = entries.filter { ids.contains($0.key) } }
        mutating func clear() { entries.removeAll() }
    }

    private static let cacheFailureCodes: Set<String> = [
        "media_cache_unavailable", "media_cache_invalid_response", "media_cache_invalid_descriptor",
        "media_cache_file_missing", "media_cache_audio_missing", "media_cache_failed",
        "media_cache_corrupt", "media_cache_limit", "media_cache_missing", "media_cancelled",
        "media_disk_full", "media_download_body", "media_download_connect", "media_download_failed",
        "media_download_http_401", "media_download_http_403", "media_download_http_404",
        "media_download_http_429", "media_download_http_5xx", "media_download_http_status",
        "media_download_timeout", "media_download_transport", "media_helper_integrity_failed",
        "media_helper_unavailable", "media_interrupted", "media_invalid_content", "media_invalid_range",
        "media_live_unsupported", "media_queue_full", "media_resolve_failed", "media_resolve_timeout",
        "media_restricted", "media_storage_corrupt", "media_unsupported_format", "media_unsupported_site"
    ]

    static func failureDiagnostic(_ state: WorldScreenSurfaceState) -> String? {
        guard case let .failed(.nativeLink(info)) = state else { return nil }
        let raw = info.technicalDescription
        let candidate = String(raw.prefix { $0 != " " && $0 != "=" })
        let allowed = Set(["cancelled", "empty_input", "malformed_url", "unsupported_scheme", "unsupported_site", "helper_missing", "helper_not_executable", "helper_sha256_mismatch", "helper_version_mismatch", "helper_launch_failed", "helper_timed_out", "network_unreachable", "helper_failed", "login_required", "members_only", "geo_restricted", "drm_protected", "not_found", "no_playable_stream", "output_unreadable", "unsupported_platform"])
        let code = allowed.contains(candidate) || cacheFailureCodes.contains(candidate) ? candidate : "unknown"
        var phase = "unknown", domain = "none", numericCode = "none"
        if raw.hasPrefix("output_unreadable=") {
            let reason = String(raw.dropFirst("output_unreadable=".count))
            if let status = httpStatus(raw) { phase = "http"; domain = "GMGNScreenLinkHTTPErrorDomain"; numericCode = String(status) }
            else if ["json", "player_init", "frame_output", "composition_video"].contains(reason) { phase = reason }
            else {
                for knownDomain in ["AVFoundationErrorDomain", "NSURLErrorDomain", "CoreMediaErrorDomain"] {
                    let prefix = knownDomain + "#"
                    guard reason.hasPrefix(prefix) else { continue }
                    let digits = String(reason.dropFirst(prefix.count).prefix { $0 != ":" })
                    guard digits.count <= 11, let number = Int32(digits) else { continue }
                    phase = "native_asset"; domain = knownDomain; numericCode = String(number)
                    break
                }
            }
        }
        return "code=\(code) phase=\(phase) domain=\(domain) numericCode=\(numericCode)"
    }

    static func httpStatus(_ diagnostic: String) -> Int? {
        let prefix = "output_unreadable=http_status_"
        guard diagnostic.hasPrefix(prefix), let status = Int(diagnostic.dropFirst(prefix.count)), (100...599).contains(status) else { return nil }
        return status
    }

    init(defaults: UserDefaults, state: @escaping () -> WorldState?, displayName: @escaping (String) -> String,
         currentTrack: @escaping () -> CurrentTrack? = { nil }) {
        self.state = state; names = displayName
        self.currentTrack = currentTrack
        videos = StageVideoPlaybackStore(defaults: defaults)
        screens = NativeScreenPlaybackCoordinator(cache: ScreenMediaCacheClient(), registry: registry)
        backgroundFrames = UnityStageVideoFrames(player: videos.player)
    }

    /// Observe the actual loaded music identity once per change, never restart a
    /// looping video on every frame. The original store owns bindings and opt-out.
    private func followCurrentTrack() {
        let track = currentTrack()
        guard track?.id != followedTrackID else { return }
        followedTrackID = track?.id
        guard let track else { videos.dismissBoundVideoPrompt(); return }
        videos.apply(track.cue, trackID: track.id, trackTitle: track.title)
    }

    private func definition(_ id: String) -> WorldScreenDefinition? {
        guard let object = state()?.objectStates[id], object.isEnabled else { return nil }
        let size = object.generatedProp?.effectiveSize
        if object.metadata[WorldScreenMetadataKey.definition] == nil,
           object.generatedProp?.assetID == "sha256:dffb417b8b2e83edf85c44c8ce64d4f04d474e0278764e1da63e02b4320cab54",
           let size {
            // Author calibration measured from this immutable GLB's display aperture.
            // Match GltfWorldAssetLoader's source-to-authoritative-size normalization.
            let quad = WorldScreenQuad(center: SIMD3<Float>(0, (0.02325 + 0.31391224) * size.y / 0.6287339,
                0.50449798 * size.z / 1.0078979), halfWidth: 0.493 * size.x / 1.0078958,
                halfHeight: 0.28025 * size.y / 0.6287339)
            return WorldScreenDefinition(objectID: id, source: .calibrated, quad: quad,
                note: "按正式电视 GLB 的显示内缘标定；保留边框与底座。")
        }
        // An unlabelled generated model needs an authored display surface, not a name/bounds guess.
        guard object.metadata[WorldScreenMetadataKey.definition] != nil else { return nil }
        let result = WorldScreenResolution.resolve(objectID: id,
            calibratedJSON: object.metadata[WorldScreenMetadataKey.definition],
            size: size.map { SIMD3<Float>($0.x, $0.y, $0.z) },
            allowsDefault: false)
        guard case let .success(value) = result else { return nil }
        return value
    }

    private func quad(_ id: String) -> [SIMD3<Float>]? {
        guard let object = state()?.objectStates[id], let definition = definition(id) else { return nil }
        let p = object.transform.position, q = object.transform.rotation
        let yaw = atan2(2 * (q.w * q.y + q.x * q.z), 1 - 2 * (q.y * q.y + q.z * q.z))
        return definition.quad.worldCorners(placedAt: SIMD3<Float>(p.x, p.y, p.z), yaw: yaw)
    }

    // Panel text never carries searched paths, stream URLs or helper stderr.
    // Retain only known diagnostic codes, without their associated payloads.
    static func safeStateText(_ state: WorldScreenSurfaceState) -> String {
        switch state {
        case .idle: return "未开始"
        case .loading: return "正在取流"
        case .playing: return "播放中"
        case .stopped: return "已停止"
        case let .failed(failure):
            guard case let .nativeLink(info) = failure else { return "失败：\(failure.panelText)" }
            if let status = httpStatus(info.technicalDescription) { return "取流失败：HTTP \(status)" + (status == 403 ? "，视频源拒绝了媒体请求。" : "。") }
            let code = String(info.technicalDescription.prefix { $0 != " " && $0 != "=" })
            let allowed = Set(["cancelled", "empty_input", "malformed_url", "unsupported_scheme", "unsupported_site", "helper_missing", "helper_not_executable", "helper_sha256_mismatch", "helper_version_mismatch", "helper_launch_failed", "helper_timed_out", "network_unreachable", "helper_failed", "login_required", "members_only", "geo_restricted", "drm_protected", "not_found", "no_playable_stream", "output_unreadable", "unsupported_platform"])
            return "失败：\(failure.panelText)" + (allowed.contains(code) || cacheFailureCodes.contains(code) ? "（\(code)）" : "")
        }
    }

    func listScreens() -> [WorldScreenSnapshot] {
        (state()?.objectStates.keys.sorted() ?? []).compactMap { id in
            guard let geometry = definition(id) else { return nil }
            let playing = screens.snapshot(for: id)
            return WorldScreenSnapshot(objectID: id, displayName: names(id), source: geometry.source,
                note: geometry.note, aspect: geometry.quad.aspect, geometryIssue: nil,
                contentURL: playing?.contentURL, stateText: Self.safeStateText(playing?.state ?? .idle) + (playing?.playlistText.map { " · " + $0 } ?? ""),
                isPlaying: playing?.isPlaying ?? false, surfaceState: playing?.state ?? .idle)
        }
    }
    /// Prop tools and screen playback use the exact same geometry decision.
    /// A missing/disabled surface is not advertised as playable.
    func propCapability(objectID: String) -> ResidentPropScreenCapability? {
        guard !closed, let geometry = definition(objectID) else { return nil }
        return .init(key: WorldScreenMetadataKey.definition, source: geometry.source.rawValue,
            note: geometry.note, aspect: geometry.quad.aspect)
    }
    func unrecognizedScreenCandidates() -> [WorldScreenCandidate] {
        (state()?.objectStates.keys.sorted() ?? []).compactMap { id in
            guard let object = state()?.objectStates[id], object.isEnabled,
                  WorldScreenEligibility.isScreenCandidate(objectID: id, displayName: names(id)), definition(id) == nil else { return nil }
            return WorldScreenCandidate(objectID: id, displayName: names(id), reason: "屏幕几何尚未确认。")
        }
    }
    func playScreen(objectID: String?, rawContent: String) async -> WorldScreenCommandOutcome {
        let available = listScreens()
        guard !closed, let id = objectID ?? (available.count == 1 ? available.first?.objectID : nil), definition(id) != nil else {
            return .failure(.screenNotFound, "请先选择空间里已摆放的屏幕。")
        }
        let page = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !page.isEmpty else { return .needsInput("请提供要播放的视频链接。") }
        guard ScreenLinkSitePolicy.accepts(page) || ScreenMediaCacheClient.isYouTubePlaylist(page) else { return .failure(.screenContentRejected, "这条链接暂不支持原生播放。") }
        guard screens.hasSession(id) || screens.activeCount < 3 else { return .failure(.screenCapacityExceeded, "同时播放的屏幕已达到上限。") }
        screenEpochs[id, default: 0] &+= 1; operations[id]?.cancel(); operations[id] = nil
        let epoch = screenEpochs[id]!
        let result = await screens.play(objectID: id, pageURL: page, quadProvider: { [weak self] in self?.quad(id) })
        guard !closed, screenEpochs[id] == epoch, definition(id) != nil else {
            screens.remove(id); return .failure(.screenNotFound, "这次屏幕操作已停止。")
        }
        return result
    }
    func stopScreen(objectID: String?) -> WorldScreenCommandOutcome {
        let available = listScreens()
        guard let id = objectID ?? (available.count == 1 ? available.first?.objectID : nil), definition(id) != nil else {
            return .failure(.screenNotFound, "请先选择空间里已摆放的屏幕。")
        }
        screenEpochs[id, default: 0] &+= 1; operations[id]?.cancel(); operations[id] = nil; screens.stop(id)
        return .ok("屏幕已停止。", details: ["screen_id": id])
    }
    func calibrateScreen(objectID: String, widthMeters: Float, heightMeters: Float, centerHeightMeters: Float) -> WorldScreenCommandOutcome {
        // No new parallel persistence: calibration must be hooked to the world's
        // formal metadata/CAS edit by the unified host, never an in-memory override.
        .failure(.screenGeometryMissing, "屏幕范围尚未确认，请在空间编辑中调整。")
    }
    func tools(isCurrent: @escaping @MainActor () -> Bool) -> [WorldScreenTool] {
        ResidentScreenTools(control: self, isCurrent: isCurrent).tools
    }

    /// Explicit command or current authorized tool invocation only. Restored URLs
    /// are not autoplayed. A removed/unplaced device is rechecked before publish.
    func command(_ value: [String: Any]) -> Bool {
        guard !closed, let op = value["op"] as? String, Self.supportedCommands.contains(op) else { return false }
        followCurrentTrack()
        switch op {
        case "screen.list", "video.load": return true
        case "screen.play":
            guard let id = value["objectID"] as? String, state()?.objectStates[id]?.isEnabled == true else { screenCommandNotice = "屏幕已移除或不可用，请重新选择。"; return false }
            guard definition(id) != nil else { screenCommandNotice = "这件物件尚未标定显示面，暂不支持播放。"; return false }
            guard let page = value["url"] as? String, page.count <= 2048, URL(string: page)?.scheme == "https" else { screenCommandNotice = "请填写完整的 HTTPS 视频页面链接。"; return false }
            guard ScreenLinkSitePolicy.accepts(page) else { screenCommandNotice = "这条链接暂不支持原生播放。"; return false }
            guard operations[id] == nil else { screenCommandNotice = "这个屏幕正在处理上一条请求，请等待或先停止播放。"; return false }
            guard screens.hasSession(id) || screens.activeCount < 3 else { screenCommandNotice = "同时播放的屏幕已达到上限。"; return false }
            screenCommandNotice = ""
            screenEpochs[id, default: 0] &+= 1
            let epoch = screenEpochs[id]!
            operations[id] = Task { [weak self] in
                guard let self else { return }
                _ = await screens.play(objectID: id, pageURL: page, quadProvider: { [weak self] in self?.quad(id) })
                guard !closed, screenEpochs[id] == epoch else { return }
                operations[id] = nil
                if definition(id) == nil { screens.remove(id) }
            }
        case "screen.stop":
            guard let id = value["objectID"] as? String else { return false }
            screenCommandNotice = ""
            screenEpochs[id, default: 0] &+= 1
            operations[id]?.cancel(); operations[id] = nil; screens.stop(id)
        case "video.choose":
            guard panel == nil else { return false }
            let picker = NSOpenPanel(); picker.allowedContentTypes = [.movie, .video]; picker.allowsMultipleSelection = true
            panel = picker
            picker.begin { [weak self] response in
                guard let self, !self.closed else { return }
                self.panel = nil
                guard response == .OK else { return }
                self.videos.add(picker.urls)
            }
        case "video.select":
            guard let id = value["id"] as? String, videos.assets.contains(where: { $0.id == id }) else { return false }
            videos.select(id)
        case "video.remove":
            guard let id = value["id"] as? String else { return false }; videos.remove(id)
        case "video.play":
            guard let asset = videos.selectedAsset,
                  (try? asset.url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
            if !videos.isUserEnabled && videos.player.currentItem == nil { videos.select(asset.id) }
            else { videos.resume() }
        case "video.pause": videos.pause()
        case "video.stop": videos.disableByUser()
        case "video.mode":
            guard let mode = value["value"] as? String, let selected = StageVideoPlaybackMode(rawValue: mode) else { return false }
            videos.setMode(selected)
        case "video.brightness":
            guard let v = value["value"] as? Double, v.isFinite, (0...1).contains(v) else { return false }
            videos.setBrightness(Float(v))
        case "video.bind":
            guard let track = currentTrack(), value["trackID"] as? String == track.id,
                  let id = value["id"] as? String, videos.assets.contains(where: { $0.id == id }) else { return false }
            videos.bind(id, to: track.id)
        case "video.unbind":
            guard let track = currentTrack(), value["trackID"] as? String == track.id else { return false }
            videos.unbind(trackID: track.id)
            videos.dismissBoundVideoPrompt()
        case "video.bound.play", "video.bound.dismiss":
            guard let prompt = videos.pendingBoundVideo, value["id"] as? String == prompt.id,
                  currentTrack()?.id == prompt.trackID,
                  videos.boundAsset(for: prompt.trackID)?.id == prompt.asset.id else { return false }
            if op == "video.bound.play" { videos.playPendingBoundVideo() }
            else { videos.dismissBoundVideoPrompt(id: prompt.id) }
        default: return false
        }
        return true
    }

    func snapshot() -> [String: Any] {
        guard !closed else { return ["screens": [], "frames": [], "video": [:]] }
        followCurrentTrack()
        for id in screens.objectIDs where definition(id) == nil {
            screenEpochs[id, default: 0] &+= 1; operations[id]?.cancel(); operations[id] = nil; screens.remove(id)
        }
        let ids = state()?.objectStates.keys.sorted().filter { definition($0) != nil } ?? []
        failureDiagnostics.retain(Set(ids))
        let surfaces: [[String: Any]] = ids.map { id in
            let session = screens.snapshot(for: id), metrics = screens.metrics(for: id)
            let playbackState = session?.state ?? .idle
            var stateText: String
            if case .loading = playbackState, let cache = session?.cacheState {
                stateText = cache.panelText
            } else {
                stateText = Self.safeStateText(playbackState)
            }
            if let playlistText=session?.playlistText {stateText += " · " + playlistText}
            if let diagnostic = failureDiagnostics.changed(Self.failureDiagnostic(session?.state ?? .idle), for: id) {
                NSLog("%@", "[UnityScreenFailure] " + diagnostic)
            }
            return ["objectID": id, "name": names(id), "state": stateText,
                "assetID": state()?.objectStates[id]?.generatedProp?.assetID ?? "",
                "geometrySource": definition(id)?.source.rawValue ?? "",
                "quad": quad(id)?.map { [$0.x, $0.y, $0.z] } ?? [],
                "playing": session?.isPlaying ?? false, "url": session?.contentURL ?? "",
                "decodedFrames": metrics?.decodedFrames as Any? ?? NSNull(),
                "hasAudio": metrics?.hasAudio as Any? ?? NSNull()]
        }
        var frames: [[String: Any]] = []
        for frame in registry.frames() where frame.isReady && frame.quad.count == 4 {
            guard let texture = frame.texture else { continue }
            // Keep recent texture identities alive across host/UI snapshot lag.
            var retained = heldTextures[frame.objectID] ?? []
            if retained.last !== texture { retained.append(texture) }
            heldTextures[frame.objectID] = Array(retained.suffix(8))
            frames.append(Self.textureDTO(texture, id: frame.objectID, corners: frame.quad))
        }
        let background = backgroundFrames.frame()
        return ["screens": surfaces, "frames": frames, "commandNotice": screenCommandNotice,
            "background": background as Any? ?? NSNull(), "video": settingsSnapshot()]
    }

    func settingsSnapshot() -> [String: Any] {
        guard !closed else { return [:] }
        followCurrentTrack()
        let track = currentTrack()
        let prompt = videos.pendingBoundVideo.flatMap { prompt in
            videos.boundAsset(for: prompt.trackID)?.id == prompt.asset.id ? prompt : nil
        }
        return ["assets": videos.assets.map { ["id": $0.id, "name": $0.displayName] },
         "selectedID": videos.selectedAssetID as Any? ?? NSNull(), "activeID": videos.activeAssetID as Any? ?? NSNull(),
         "playing": videos.isActive && videos.player.rate > 0, "mode": videos.mode.rawValue,
         "brightness": videos.brightness, "notice": notice,
         "currentTrackID": track?.id as Any? ?? NSNull(), "currentTrackTitle": track?.title as Any? ?? NSNull(),
         "boundAssetID": track.flatMap { videos.boundAsset(for: $0.id)?.id } as Any? ?? NSNull(),
         "screens": screens.objectIDs.map { id -> [String: Any] in
             let session = screens.snapshot(for: id), metric = screens.metrics(for: id)
             return ["objectID": id, "state": Self.safeStateText(session?.state ?? .idle),
                     "currentSeconds": metric?.currentSeconds as Any? ?? NSNull(),
                     "durationSeconds": metric?.durationSeconds as Any? ?? NSNull(),
                     "playbackRate": metric?.playbackRate as Any? ?? NSNull(),
                     "timeControlStatus": metric?.timeControlStatus as Any? ?? NSNull(),
                     "waitingReason": metric?.waitingReason as Any? ?? NSNull(),
                     "decodedFrames": metric?.decodedFrames as Any? ?? NSNull(),
                     "playbackEndCount": metric?.playbackEndCount as Any? ?? NSNull(),
                     "isLive": metric?.isLive as Any? ?? NSNull(),
                     "playlistIndex": session?.playlist?.currentIndex as Any? ?? NSNull(),
                     "playlistCount": session?.playlist?.items.count as Any? ?? NSNull(),
                     "playlistRevision": session?.playlist?.revision as Any? ?? NSNull()]
         },
         "pendingBoundVideo": prompt.map { ["id": $0.id, "trackID": $0.trackID, "trackTitle": $0.trackTitle,
                                              "assetID": $0.asset.id, "assetName": $0.asset.displayName] } as Any? ?? NSNull()]
    }
    static func textureDTO(_ texture: MTLTexture, id: String, corners: [SIMD3<Float>]) -> [String: Any] {
        ["objectID": id, "texturePointer": String(UInt(bitPattern: Unmanaged.passUnretained(texture as AnyObject).toOpaque()), radix: 16),
         "width": texture.width, "height": texture.height, "format": "bgra8",
         "quad": corners.map { [$0.x, $0.y, $0.z] }]
    }
    func close() {
        closed = true; panel?.cancel(nil); panel = nil
        operations.values.forEach { $0.cancel() }; operations.removeAll()
        screens.stopAll(); videos.stop(); backgroundFrames.close(); heldTextures.removeAll()
        failureDiagnostics.clear()
    }
}

/// Pulls decoded AVPlayerItemVideoOutput buffers from the original stage player.
/// CVMetalTexture wraps IOSurface on GPU; no CPU pixel copy or second audio owner.
@MainActor private final class UnityStageVideoFrames {
    private let player: AVQueuePlayer
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    private var item: AVPlayerItem?
    private var cache: CVMetalTextureCache?
    private var leases: [(CVPixelBuffer, CVMetalTexture)] = []
    private var current: MTLTexture?
    init(player: AVQueuePlayer) {
        self.player = player
        if let device = MTLCreateSystemDefaultDevice() { CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) }
    }
    func frame() -> [String: Any]? {
        guard let selected = player.currentItem, let cache else { return nil }
        if item !== selected { item?.remove(output); item = selected; selected.add(output); current = nil }
        let time = selected.currentTime()
        if output.hasNewPixelBuffer(forItemTime: time), let pixels = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            var wrapped: CVMetalTexture?
            let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
            if CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixels, nil, .bgra8Unorm, w, h, 0, &wrapped) == kCVReturnSuccess,
               let wrapped, let texture = CVMetalTextureGetTexture(wrapped) {
                leases.append((pixels, wrapped)); leases = Array(leases.suffix(8)); current = texture
            }
        }
        return current.map { UnityScreenVideoBridge.textureDTO($0, id: "stage.background-video", corners: []) }
    }
    func close() { item?.remove(output); item = nil; current = nil; leases.removeAll() }
}
