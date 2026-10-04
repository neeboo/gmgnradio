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
    private var session: UInt64 = 0
    private var lines: [StageLyricLine] = []
    private var lyricRevision: UInt64 = 0
    private var emittedLyricRevision: UInt64?
    private var notice: String?
    private var openPanel: NSOpenPanel?
    private var closed = false
    private var pausedPosition: TimeInterval?

    init(root: URL, defaults: UserDefaults) throws {
        graph = AudioGraphController(visualStore: features)
        player = LocalMusicPlayer(graph: graph)
        chat = try RenderHostResidentConversation(backend: "dsh", dataRoot: root, defaults: defaults)
    }

    func command(_ value: [String: Any]) -> Bool {
        do {
            switch value["op"] as? String {
            case "music.choose":
                guard openPanel == nil else { return false }
                let panel = NSOpenPanel()
                panel.title = "选择音乐"
                panel.allowedContentTypes = [.audio]
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                openPanel = panel
                let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                    guard let self else { return }
                    self.openPanel = nil
                    guard !self.closed, response == .OK, let url = panel.url else { return }
                    var load: [String: Any] = ["op": "music.load", "path": url.path, "autoplay": true]
                    let lrc = url.deletingPathExtension().appendingPathExtension("lrc")
                    if FileManager.default.fileExists(atPath: lrc.path) { load["lyricPath"] = lrc.path }
                    _ = self.command(load)
                }
                if let window = NSApplication.shared.keyWindow {
                    panel.beginSheetModal(for: window, completionHandler: completion)
                } else { panel.begin(completionHandler: completion) }
                return true
            case "music.load":
                guard let path = value["path"] as? String, path.hasPrefix("/") else { return false }
                session &+= 1
                pausedPosition = nil
                lyricRevision &+= 1
                lines = []
                player.stop()
                try player.load(URL(fileURLWithPath: path))
                if let lyricPath = value["lyricPath"] as? String, lyricPath.hasPrefix("/") {
                    let text = try String(contentsOfFile: lyricPath, encoding: .utf8)
                    lines = StageLyricsParser().parse(MusicLyrics(original: text, translation: nil), trackDuration: player.track?.duration)
                }
                if value["autoplay"] as? Bool == true { try player.play() }
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
        return ["version": 1, "music": music, "chat": chat.poll()]
    }

    func close() {
        closed = true
        openPanel?.cancel(nil)
        openPanel = nil
        player.stop()
        chat.close()
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
