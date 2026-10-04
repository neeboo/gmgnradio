import Foundation
import AppKit
import UniformTypeIdentifiers

/// Unity owns the window and renderer. This host constructs only the actual
/// audio graph and isolated DSH conversation, never AppDelegate or a scene.
@MainActor
final class UnityMediaHost {
    let features = VisualAudioFeatureStore()
    let graph: AudioGraphController
    let player: LocalMusicPlayer
    let chat: RenderHostResidentConversation
    let world: UnityWorldBridge
    private var session: UInt64 = 0
    private var lines: [StageLyricLine] = []
    private var lyricRevision: UInt64 = 0
    private var emittedLyricRevision: UInt64?
    private var notice: String?
    private var openPanel: NSOpenPanel?
    private var closed = false
    private var pausedPosition: TimeInterval?
    private struct QueueEntry {
        let url: URL
        let lyricURL: URL?
    }
    private var queue: [QueueEntry] = []
    private var queueIndex = 0

    init(root: URL, defaults: UserDefaults) throws {
        world = UnityWorldBridge(root: root)
        graph = AudioGraphController(visualStore: features)
        player = LocalMusicPlayer(graph: graph)
        chat = try RenderHostResidentConversation(backend: "dsh", dataRoot: root, defaults: defaults)
        player.setCompletionHandler { [weak self] in
            guard let self, self.queueIndex + 1 < self.queue.count else { return }
            _ = self.command(["op": "music.next"])
        }
    }

    private func entry(path: String, lyricPath: String? = nil) -> QueueEntry {
        let url = URL(fileURLWithPath: path)
        let adjacent = url.deletingPathExtension().appendingPathExtension("lrc")
        let lyric = lyricPath.map { URL(fileURLWithPath: $0) }
            ?? (FileManager.default.fileExists(atPath: adjacent.path) ? adjacent : nil)
        return QueueEntry(url: url, lyricURL: lyric)
    }

    private func loadQueueEntry(autoplay: Bool) throws {
        let selected = queue[queueIndex]
        session &+= 1
        pausedPosition = nil
        lyricRevision &+= 1
        lines = []
        player.stop()
        try player.load(selected.url)
        // A bad optional lyric must not prevent an otherwise valid song playing.
        if let lyric = selected.lyricURL,
           let text = try? String(contentsOf: lyric, encoding: .utf8) {
            lines = StageLyricsParser().parse(MusicLyrics(original: text, translation: nil), trackDuration: player.track?.duration)
        }
        if autoplay { try player.play() }
    }

    func command(_ value: [String: Any]) -> Bool {
        do {
            switch value["op"] as? String {
            case "world.snapshot", "world.commit":
                return world.command(value)
            case "music.choose":
                guard openPanel == nil else { return false }
                let panel = NSOpenPanel()
                panel.title = "选择音乐"
                panel.allowedContentTypes = [.audio]
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = false
                openPanel = panel
                let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                    guard let self else { return }
                    self.openPanel = nil
                    guard !self.closed, response == .OK, !panel.urls.isEmpty else { return }
                    _ = self.command(["op": "music.queue", "paths": panel.urls.map(\.path), "autoplay": true])
                }
                if let window = NSApplication.shared.keyWindow {
                    panel.beginSheetModal(for: window, completionHandler: completion)
                } else { panel.begin(completionHandler: completion) }
                return true
            case "music.load":
                guard let path = value["path"] as? String, path.hasPrefix("/") else { return false }
                let rawLyric = value["lyricPath"] as? String
                let lyric = rawLyric.flatMap { $0.isEmpty ? nil : $0 }
                guard lyric == nil || lyric!.hasPrefix("/") else { return false }
                queue = [entry(path: path, lyricPath: lyric)]
                queueIndex = 0
                try loadQueueEntry(autoplay: value["autoplay"] as? Bool == true)
            case "music.queue":
                guard let paths = value["paths"] as? [String], !paths.isEmpty,
                      paths.allSatisfy({ $0.hasPrefix("/") }) else { return false }
                let index = value["index"] as? Int ?? 0
                guard paths.indices.contains(index) else { return false }
                queue = paths.map { entry(path: $0) }
                queueIndex = index
                try loadQueueEntry(autoplay: value["autoplay"] as? Bool == true)
            case "music.next":
                guard queueIndex + 1 < queue.count else { return false }
                queueIndex += 1
                try loadQueueEntry(autoplay: true)
            case "music.select":
                guard let index = value["index"] as? Int, queue.indices.contains(index) else { return false }
                queueIndex = index
                try loadQueueEntry(autoplay: true)
            case "music.previous":
                guard queueIndex > 0 else { return false }
                queueIndex -= 1
                try loadQueueEntry(autoplay: true)
            case "music.play":
                try player.play()
                pausedPosition = nil
            case "music.pause":
                if player.isGraphPlaying { pausedPosition = player.playbackPosition }
                player.pause()
            case "music.stop":
                player.stop()
                pausedPosition = nil
            case "music.volume":
                guard let volume = value["value"] as? Double, volume.isFinite, (0...1).contains(volume) else { return false }
                graph.musicVolume = Float(volume)
            case "music.seek": notice = "当前音乐后端尚未提供跳转。"; return false
            case "chat.send":
                guard let id = value["requestID"] as? NSNumber, let text = value["text"] as? String else { return false }
                return chat.send(requestID: id.uint64Value, text: text)
            case "chat.cancel":
                guard let id = value["requestID"] as? NSNumber else { return false }
                return chat.cancel(requestID: id.uint64Value)
            default: return false
            }
            notice = nil
            return true
        } catch { notice = error.localizedDescription; return false }
    }

    func snapshot() -> [String: Any] {
        let f = features.current
        var music: [String: Any] = ["playbackSessionID": session,
            "title": player.track?.title ?? "", "duration": player.track?.duration ?? 0,
            "position": pausedPosition ?? player.playbackPosition, "isPlaying": player.isGraphPlaying,
            "volume": graph.musicVolume, "seekSupported": false,
            "canNext": queueIndex + 1 < queue.count, "canPrevious": queueIndex > 0,
            "queueIndex": queueIndex, "queueCount": queue.count,
            "queue": queue.enumerated().map { ["index": $0.offset, "title": $0.element.url.deletingPathExtension().lastPathComponent] },
            "features": ["amplitude": f.amplitude, "low": f.low, "mid": f.mid,
                         "high": f.high, "beat": f.beat, "onset": f.onset],
            "lyricRevision": lyricRevision,
            "notice": notice as Any? ?? NSNull()]
        // Raw timeline is sent once per song; no per-frame style layout or
        // full timeline retransmission. An empty lines array clears old lyrics.
        if emittedLyricRevision != lyricRevision {
            music["lines"] = lines.map { ["id": $0.id, "text": $0.text, "start": $0.startsAt, "end": $0.endsAt] }
            emittedLyricRevision = lyricRevision
        }
        var conversation = chat.poll()
        conversation["capabilities"] = ["streamingReplies": true, "deltaTextMode": "replace",
            "cancelActiveReply": true, "cancellationAcknowledgement": "local-turn-invalidated",
            "providerCancellationAcknowledgement": false]
        return ["version": 1, "music": music, "chat": conversation, "world": world.snapshot()]
    }

    func close() {
        closed = true
        openPanel?.cancel(nil)
        openPanel = nil
        player.stop()
        chat.close()
        world.close()
    }
}

private func withUnityHost<T: Sendable>(_ handle: UnsafeMutableRawPointer?, _ body: @MainActor (UnityMediaHost) -> T) -> T? {
    guard Thread.isMainThread, let handle else { return nil }
    let address = UInt(bitPattern: handle)
    return MainActor.assumeIsolated {
        body(Unmanaged<UnityMediaHost>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue())
    }
}

@_cdecl("gmgn_unity_host_create")
public func gmgnUnityHostCreate(_ root: UnsafePointer<CChar>?, _ suite: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread else {
        NSLog("[UnityMediaHost] create rejected: caller is not the macOS main thread")
        return nil
    }
    guard let root, let suite else { NSLog("[UnityMediaHost] create rejected: missing isolated root or suite"); return nil }
    let path = String(cString: root), name = String(cString: suite)
    guard path.hasPrefix("/"), path != "/", name.hasPrefix("ai.gmgn.unity-sample."),
          let defaults = UserDefaults(suiteName: name) else {
        NSLog("[UnityMediaHost] create rejected: invalid isolated root or defaults suite")
        return nil
    }
    let address: UInt? = MainActor.assumeIsolated {
        do {
            let host = try UnityMediaHost(root: URL(fileURLWithPath: path), defaults: defaults)
            return UInt(bitPattern: Unmanaged.passRetained(host).toOpaque())
        } catch {
            // Only our closed, credential-free connection error is disclosed.
            // Provider errors or arbitrary paths/details never reach logs.
            if let connection = error as? RenderHostDSHConnectionError {
                NSLog("[UnityMediaHost] create failed: %@", connection.localizedDescription)
            } else {
                NSLog("[UnityMediaHost] create failed: isolated initialization error (%@)", String(describing: type(of: error)))
            }
            return nil
        }
    }
    return address.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
}

@_cdecl("gmgn_unity_host_command")
public func gmgnUnityHostCommand(_ handle: UnsafeMutableRawPointer?, _ json: UnsafePointer<CChar>?) -> Int32 {
    guard let json, let data = String(cString: json).data(using: .utf8), data.count <= 256 * 1024,
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
    return withUnityHost(handle) { $0.command(value) ? 1 : 0 } ?? 0
}

@_cdecl("gmgn_unity_host_snapshot")
public func gmgnUnityHostSnapshot(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
    let address: UInt? = withUnityHost(handle) { host in
        guard let data = try? JSONSerialization.data(withJSONObject: host.snapshot()),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return strdup(text).map { UInt(bitPattern: $0) }
    } ?? nil
    return address.flatMap { UnsafeMutablePointer<CChar>(bitPattern: $0) }
}

@_cdecl("gmgn_unity_host_destroy")
public func gmgnUnityHostDestroy(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard Thread.isMainThread, let handle else { return 0 }
    let address = UInt(bitPattern: handle)
    return MainActor.assumeIsolated {
        let host = Unmanaged<UnityMediaHost>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeRetainedValue()
        host.close()
        return 1
    }
}

@_cdecl("gmgn_unity_host_string_free")
public func gmgnUnityHostStringFree(_ text: UnsafeMutablePointer<CChar>?) { free(text) }

@_cdecl("gmgn_unity_window_scale")
public func gmgnUnityWindowScale() -> Double {
    guard Thread.isMainThread else { return 1 }
    return MainActor.assumeIsolated {
        Double((NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible }))?.backingScaleFactor ?? 1)
    }
}

@_cdecl("gmgn_unity_window_width")
public func gmgnUnityWindowWidth() -> Double {
    guard Thread.isMainThread else { return 0 }
    return MainActor.assumeIsolated {
        Double((NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible && $0.contentView != nil }))?.contentView?.bounds.width ?? 0)
    }
}

@_cdecl("gmgn_unity_screen_pixels")
public func gmgnUnityScreenPixels(_ axis: Int32) -> Double {
    guard Thread.isMainThread else { return 0 }
    return MainActor.assumeIsolated {
        guard let screen = (NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible }))?.screen else { return 0 }
        return Double((axis == 0 ? screen.frame.width : screen.frame.height) * screen.backingScaleFactor)
    }
}
