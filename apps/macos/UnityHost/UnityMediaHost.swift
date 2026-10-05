import Foundation
import AppKit
import UniformTypeIdentifiers
import AVFoundation

/// Unity owns the window and renderer. This host constructs only the actual
/// audio graph and isolated DSH conversation, never AppDelegate or a scene.
@MainActor
final class UnityMediaHost {
    let features = VisualAudioFeatureStore()
    let graph: AudioGraphController
    let player: LocalMusicPlayer
    let chat: RenderHostResidentConversation
    let world: UnityWorldBridge
    let musicLibrary: UnityMusicLibraryBridge
    private var libraryQueueActive = false
    private var libraryTrack: MusicCandidate?
    private var musicQueueRevision: UInt64 = 0
    private var emittedMusicQueueRevision: UInt64?
    private let root: URL
    private let productSettings: UnityProductSettings
    private let visualDirection: StageVisualDirectionStore
    private let visualTimeline = StageVisualPresetTimeline()
    private let visualEpoch = ProcessInfo.processInfo.systemUptime
    private let lyricsStore: StageLyricsStore
    private var visualRevision: UInt64 = 0
    private var settingsBridge: UnitySettingsBridge?
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
        self.root = root
        lyricsStore = StageLyricsStore(defaults: defaults)
        productSettings = UnityProductSettings(root: root, defaults: defaults)
        visualDirection = StageVisualDirectionStore(defaults: defaults)
        world = UnityWorldBridge(root: root)
        musicLibrary = UnityMusicLibraryBridge(root: root)
        graph = AudioGraphController(visualStore: features)
        if ProcessInfo.processInfo.environment["GMGN_UNITY_TEST_MUTED"] == "1" {
            graph.musicVolume = 0
        }
        player = LocalMusicPlayer(graph: graph)
        chat = try RenderHostResidentConversation(backend: "dsh", dataRoot: root, defaults: defaults)
        player.setCompletionHandler { [weak self] in
            guard let self else { return }
            _ = self.command(["op": "music.next"])
        }
        musicLibrary.onPrepared = { [weak self] url, lyrics, candidate in
            guard let self, !self.closed else { return false }
            do {
                // Validate the file before the shared graph stops its old node.
                _ = try AVAudioFile(forReading: url)
                try self.player.load(url)
                try self.player.play()
                self.session &+= 1; self.pausedPosition = nil
                self.queue = [self.entry(path: url.path)]; self.queueIndex = 0
                self.lyricsStore.clear(); self.lines = []; self.lyricRevision &+= 1
                self.libraryQueueActive = true; self.libraryTrack = candidate
                self.musicQueueRevision &+= 1
                if let lyrics {
                    self.lyricsStore.publish(lyrics, trackID: candidate.id, trackDuration: candidate.duration)
                    self.lines = self.lyricsStore.lines; self.lyricRevision &+= 1
                }
                return true
            } catch { self.notice = "这首歌未能开始播放，请选择另一首重试。"; return false }
        }
        settingsBridge = try? UnitySettingsBridge(root: root,
            command: { [weak self] value in self?.settingsCommand(value) ?? false },
            snapshot: { [weak self] in
                guard let self else { return [:] }
                return self.settingsSnapshot()
            })
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
        lyricsStore.clear()
        player.stop()
        try player.load(selected.url)
        // A bad optional lyric must not prevent an otherwise valid song playing.
        if let lyric = selected.lyricURL,
           let text = try? String(contentsOf: lyric, encoding: .utf8) {
            let translationURL = selected.url.deletingPathExtension().appendingPathExtension("translation.lrc")
            let yrcURL = selected.url.deletingPathExtension().appendingPathExtension("yrc")
            let translation = try? String(contentsOf: translationURL, encoding: .utf8)
            let wordByWord = try? String(contentsOf: yrcURL, encoding: .utf8)
            lyricsStore.publish(MusicLyrics(original: text, translation: translation, wordByWord: wordByWord),
                                trackID: selected.url.path, trackDuration: player.track?.duration)
            lines = lyricsStore.lines
        }
        if autoplay { try player.play() }
    }

    func command(_ value: [String: Any]) -> Bool {
        do {
            switch value["op"] as? String {
            case "settings.open": return settingsBridge?.open() ?? false
            case "stage.load": return true
            case "stage.player.lyrics":
                guard let id = value["id"] as? String,
                      let mode = StageLyricsVisualMode.allCases.first(where: { $0.agentValue == id }) else { return false }
                lyricsStore.setVisualMode(mode)
                visualRevision &+= 1
            case "stage.player.cloud", "stage.player.particles": return settingsCommand(value)
            case "world.snapshot", "world.commit", "world.placement.evaluate", "world.placement.derive":
                return world.command(value)
            case "music.library": return musicLibrary.refresh()
            case "music.playlist":
                guard let id = value["playlistID"] as? String else { return false }
                return musicLibrary.readPlaylist(id)
            case "music.playlist.play":
                guard let id = value["playlistID"] as? String, let index = value["index"] as? Int else { return false }
                return musicLibrary.play(playlistID: id, index: index)
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
                musicLibrary.clearQueue(); libraryQueueActive = false; libraryTrack = nil
                musicQueueRevision &+= 1
                queue = [entry(path: path, lyricPath: lyric)]
                queueIndex = 0
                try loadQueueEntry(autoplay: value["autoplay"] as? Bool == true)
            case "music.queue":
                guard let paths = value["paths"] as? [String], !paths.isEmpty,
                      paths.allSatisfy({ $0.hasPrefix("/") }) else { return false }
                let index = value["index"] as? Int ?? 0
                guard paths.indices.contains(index) else { return false }
                musicLibrary.clearQueue(); libraryQueueActive = false; libraryTrack = nil
                musicQueueRevision &+= 1
                queue = paths.map { entry(path: $0) }
                queueIndex = index
                try loadQueueEntry(autoplay: value["autoplay"] as? Bool == true)
            case "music.next":
                if libraryQueueActive { return musicLibrary.select(musicLibrary.index + 1) }
                guard queueIndex + 1 < queue.count else { return false }
                queueIndex += 1
                try loadQueueEntry(autoplay: true)
            case "music.select":
                if libraryQueueActive, let index = value["index"] as? Int { return musicLibrary.select(index) }
                guard let index = value["index"] as? Int, queue.indices.contains(index) else { return false }
                queueIndex = index
                try loadQueueEntry(autoplay: true)
            case "music.previous":
                if libraryQueueActive { return musicLibrary.select(musicLibrary.index - 1) }
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
            "title": libraryTrack?.title ?? player.track?.title ?? "", "duration": player.track?.duration ?? 0,
            "position": pausedPosition ?? player.playbackPosition, "isPlaying": player.isGraphPlaying,
            "volume": graph.musicVolume, "seekSupported": false,
            "canNext": queueIndex + 1 < queue.count, "canPrevious": queueIndex > 0,
            "queueIndex": queueIndex, "queueCount": queue.count,
            "features": ["amplitude": f.amplitude, "low": f.low, "mid": f.mid,
                         "high": f.high, "bass": f.bass, "vocal": f.vocal, "treble": f.treble,
                         "beat": f.beat, "onset": f.onset],
            "lyricRevision": lyricRevision,
            "lyricVisual": playerVisualSettingsSnapshot(),
            "pointCloud": pointCloudSnapshot(),
            "notice": notice as Any? ?? NSNull()]
        if libraryQueueActive {
            music["canNext"] = musicLibrary.index + 1 < musicLibrary.queue.count
            music["canPrevious"] = musicLibrary.index > 0
            music["queueIndex"] = musicLibrary.index; music["queueCount"] = musicLibrary.queue.count
        }
        if emittedMusicQueueRevision != musicQueueRevision {
            music["queue"] = libraryQueueActive
                ? musicLibrary.queue.enumerated().map { ["index": $0.offset, "title": $0.element.title] }
                : queue.enumerated().map { ["index": $0.offset, "title": $0.element.url.deletingPathExtension().lastPathComponent] }
            emittedMusicQueueRevision = musicQueueRevision
        }
        // Raw timeline is sent once per song; no per-frame style layout or
        // full timeline retransmission. An empty lines array clears old lyrics.
        if emittedLyricRevision != lyricRevision {
            music["lines"] = lines.map { line in
                ["id": line.id, "text": line.text, "translation": line.translation as Any? ?? NSNull(),
                 "start": line.startsAt, "end": line.endsAt, "startsAt": line.startsAt, "endsAt": line.endsAt,
                 "words": line.words.map { ["id": $0.id, "text": $0.text, "startsAt": $0.startsAt, "endsAt": $0.endsAt] }] as [String: Any]
            }
            emittedLyricRevision = lyricRevision
        }
        var conversation = chat.poll()
        conversation["capabilities"] = ["streamingReplies": true, "deltaTextMode": "replace",
            "cancelActiveReply": true, "cancellationAcknowledgement": "local-turn-invalidated",
            "providerCancellationAcknowledgement": false]
        return ["version": 1, "music": music, "musicLibrary": musicLibrary.snapshot(), "chat": conversation, "world": world.snapshot()]
    }

    func close() {
        closed = true
        openPanel?.cancel(nil)
        openPanel = nil
        player.stop()
        chat.close()
        world.close()
        musicLibrary.close()
        settingsBridge?.close()
        productSettings.close()
    }

    private func settingsCommand(_ value: [String: Any]) -> Bool {
        guard !closed, let op = value["op"] as? String else { return false }
        switch op {
        case "settings.load":
            _ = musicLibrary.settingsCommand(["op": "music.load"])
            return productSettings.command(value)
        case "music.load", "music.connect", "music.disconnect", "music.sync": return musicLibrary.settingsCommand(value)
        case "stage.load": return true
        case "stage.player.lyrics": return command(value)
        case "stage.player.cloud":
            guard let raw = value["id"] as? String, let choice = StagePointCloudChoice(rawValue: raw) else { return false }
            visualDirection.selectPointCloud(choice); visualRevision &+= 1; return true
        case "stage.player.particles":
            guard let number = value["value"] as? NSNumber, number.floatValue.isFinite,
                  StageParticleSizing.manualRange.contains(number.floatValue) else { return false }
            visualDirection.setParticleSizeMultiplier(number.floatValue); visualRevision &+= 1; return true
        default: return productSettings.command(value)
        }
    }

    private func settingsSnapshot() -> [String: Any] {
        var settings = productSettings.snapshot
        settings["music"] = musicLibrary.settingsSnapshot
        settings["unity"] = ["availableSections": ["歌词", "视觉效果", "语音播放", "按住说话", "自主行动", "音乐账号与歌单同步"],
                             "availableAgentGroups": ["回复语音", "按住说话", "居民人格"],
                             "autoSpeakSupported": false,
                             "unavailableMessage": "此设置尚未接入 Unity；角色、快捷键、视频与空间活动仍由原应用管理。"]
        return ["version": 1, "revision": visualRevision, "settings": settings,
                "stage": ["mode": "player", "stageRadioPluginEnabled": true,
                          "player": ["lyrics": StageLyricsVisualMode.allCases.map { ["id": $0.agentValue, "name": $0.displayName] },
                                     "lyricID": lyricsStore.visualMode.agentValue,
                                     "clouds": StagePointCloudChoice.allCases.map { ["id": $0.rawValue, "name": $0.title] },
                                     "cloudID": visualDirection.currentPointCloudChoice.rawValue,
                                     "particleScale": visualDirection.particleSizeMultiplier]],
                "supportedCommands": ["settings.load", "speech.settings.load", "speech.settings.cancel", "stage.load",
                                      "stage.player.lyrics", "stage.player.cloud", "stage.player.particles", "agent.save",
                                      "tts.provider", "tts.refresh", "tts.save", "tts.preview", "tts.stop", "asr.provider", "asr.save",
                                      "music.load", "music.connect", "music.disconnect", "music.sync"]]
    }

    private func pointCloudSnapshot() -> [String: Any] {
        let automatic = visualTimeline.sample(at: Float(ProcessInfo.processInfo.systemUptime - visualEpoch))
        let frame = visualDirection.currentPointCloudChoice.resolvedPresetFrame(automatic: automatic)
        return ["choice": visualDirection.currentPointCloudChoice.rawValue,
                "intensity": visualDirection.currentIntensity, "particleSize": visualDirection.particleSizeMultiplier,
                "presetWeights": [frame.weights.x, frame.weights.y, frame.weights.z], "composition": frame.composition,
                "artworkURL": libraryTrack?.artworkURL?.absoluteString as Any? ?? NSNull(),
                "rhythm": [features.current.beat, features.current.onset, features.current.amplitude,
                           (0..<8).reduce(Float.zero) { $0 + features.current.waveform[$1] } / 8],
                "waveA": (0..<4).map { features.current.waveform[$0] },
                "waveB": (4..<8).map { features.current.waveform[$0] }]
    }

    private func playerVisualSettingsSnapshot() -> [String: Any] {
        let mode = StageLyricModeDirector.resolve(configuredMode: lyricsStore.visualMode,
            trackID: lyricsStore.trackID, lines: lines, playbackTime: pausedPosition ?? player.playbackPosition)
        let theme = lyricsStore.activeTheme ?? .gmgnDefaultDark
        let themeValue = (try? JSONEncoder().encode(theme)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        return ["revision": visualRevision, "configuredMode": lyricsStore.visualMode.agentValue,
            "mode": mode.agentValue, "theme": themeValue ?? NSNull(),
            "availableModes": StageLyricsVisualMode.allCases.map { ["id": $0.agentValue, "name": $0.displayName] },
            // The external settings pane consumes the existing StagePanelsPane shape.
            "player": ["lyricID": lyricsStore.visualMode.agentValue,
                       "lyrics": StageLyricsVisualMode.allCases.map { ["id": $0.agentValue, "name": $0.displayName] }]]
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

/// Dedicated bounded geometry path. No music/chat/general command is accepted.
/// Main thread only obtains the lifetime-safe bridge reference and copies bytes.
@_cdecl("gmgn_unity_host_placement")
public func gmgnUnityHostPlacement(_ handle: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int32) -> Int32 {
    guard Thread.isMainThread, let bytes, count > 0, count <= 64 * 1024 * 1024 else { return 0 }
    let copied = Data(bytes: bytes, count: Int(count))
    return withUnityHost(handle) { host in
        return host.world.enqueueGeometry(copied) ? Int32(1) : Int32(0)
    } ?? 0
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
