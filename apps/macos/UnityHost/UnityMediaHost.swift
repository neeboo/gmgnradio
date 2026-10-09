import Foundation
import AppKit
import UniformTypeIdentifiers
import AVFoundation
import WorldRuntime
import os

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
    private let musicStorage: MusicStorageClient
    private var inbox: UnityInboxBridge? { worldSession?.inbox }
    private let musicPlayback: RustMusicPlaybackClient
    private var libraryQueueActive: Bool { musicPlayback.state?.mode == "library" }
    private var libraryTrack: MusicCandidate?
    private var nativeMusicRequestID: String?
    private var musicQueueRevision: UInt64 = 0
    private var emittedMusicQueueRevision: UInt64?
    private let root: URL
    private let nativeHostSessionID = UUID().uuidString
    private let defaults: UserDefaults
    private let productDefaults: UserDefaults?
    private let productSettings: UnityProductSettings
    private let visualDirection: StageVisualDirectionStore
    private let visualTimeline = StageVisualPresetTimeline()
    private let visualEpoch = ProcessInfo.processInfo.systemUptime
    private let lyricsStore: StageLyricsStore
    private var visualRevision: UInt64 = 0
    private var visualCommandTask: Task<Void, Never>?
    private var visualCommandState: [String:Any] = [:]
    private var gpuiSettingsTask: Task<Void, Never>?
    private var gpuiSettingsResult: [String: Any] = [:]
    /// The named reason behind the *current* `ui.settings.command` refusal.
    /// Without it every settings refusal collapses into the anonymous
    /// `settings_command_rejected`, and a person clicking a control gets an
    /// error no log and no receipt can explain (the 选定动作 report of
    /// 2026-10-09). Cleared before each command and on close.
    private var gpuiSettingsRefusal: String?
    private static let settingsLog = Logger(subsystem: "ai.gmgn.radio", category: "SettingsCommand")
    private var session: UInt64 = 0
    private var lines: [StageLyricLine] = []
    private var lyricRevision: UInt64 = 0
    private var emittedLyricRevision: UInt64?
    private var notice: String?
    private var openPanel: NSOpenPanel?
    private var closed = false
    private var worldSession: UnityWorldSessionComposition?
    private var characterPosition: UnityCharacterPositionBridge?
    let worldPhysics = UnityWorldPhysicsClient()
    private var savedProgramRestoreTask: Task<Void, Never>?
    private var spatialSceneTransitionInProgress = false
    private var spatialSceneSelectionRevision: UInt64?
    private lazy var chatImages = UnityChatImageBridge(directory: root.appendingPathComponent("gmgn radio/UnityChatAttachments", isDirectory: true))
    private var takingChatImageRequestID: UInt64?
    private var chatImageAdmissionTask: Task<Bool, Never>?
    private let chatImageDrop = UnityChatImageDropBridge.shared
    private let humanImageConversationID = "unity-chat:" + UUID().uuidString
    private var chatImageSubmissions: [UInt64: ResidentChatSubmission] = [:]
    private var scheduledHumanSubmission: (requestID: UInt64, submission: ResidentChatSubmission, session: UnityWorldSessionComposition)?
    private lazy var spatialPresentation = UnitySpatialPresentationBridge(
        currentWorldID: { [weak self] in self?.worldSession?.context.state.worldID },
        changeWeather: { [weak self] weather in
            guard let self, !self.closed, let session = self.worldSession else { throw CancellationError() }
            try await session.context.setWeather(weather, source: .ui)
        })
    private lazy var djPreferences = DJAgentPreferences(defaults: defaults, settings: productSettings.authority)
    private lazy var djProgram = UnityDJProgramBridge(archiveRoot: root.appendingPathComponent("gmgn radio/DJPrograms", isDirectory: true),
        hooks: .init(plan: { [weak self] instruction in
            guard let self, !self.closed else { throw CancellationError() }
            return try await self.musicLibrary.makeProgramPlan(instruction: instruction, preferences: self.djPreferences)
        }, activate: { [weak self] plan in
            guard let self, !self.closed else { throw CancellationError() }
            return try await self.musicLibrary.activateProgram(plan)
        }, replaceUpcoming: { [weak self] plan, index in
            guard let self, !self.closed else { throw CancellationError() }
            try await self.musicLibrary.replaceUpcomingProgram(plan, at: index)
        }, notify: { [weak self] summary in
            guard let self, !self.closed else { return }
            self.notice = summary
            self.residentAutonomy?.receive(.init(id: UUID().uuidString, kind: "dj_program", summary: summary))
        }, restore: { [weak self] plan, savedIndex in
            guard let self, !self.closed else { throw CancellationError() }
            return try await self.musicLibrary.restoreProgram(plan, startingAt: savedIndex)
        }, selectHistorical: { [weak self] plan, slot in
            guard let self, !self.closed else { throw CancellationError() }
            return try await self.musicLibrary.activateProgram(plan, startingAt: slot)
        }), storage: musicStorage, programClient: RustMusicProgramClient(root: root.appendingPathComponent("gmgn radio/TaskService", isDirectory: true)))
    private var worldSelection: [String: Any] = [:]
    private var pendingWorldPackage: BundledLivingWorldPackage?
    private var worldSelectionTask: Task<Void, Never>?
    private var prepareWatchdogTask: Task<Void, Never>?
    /// Backstop for a renderer receipt that never arrives. The renderer's own
    /// prepare budget answers first; this only covers a lost or undeliverable
    /// `world.selection.prepared`, which used to leave the product parked on
    /// the player surface with `phase=prepare` and no named reason anywhere.
    private static let prepareWatchdogDelay = Duration.seconds(180)
    /// 启动默认呈现面是**空间**。启动那一次的世界进入是一个事务，冷启动时它会
    /// 输给三种竞态，而以前每一种都让整场会话留在**播放器**上：
    /// 权威还没起来（`world_authority_unavailable`，helper 冷启动）、
    /// 权威里还没有这个世界（`world_authority_record_missing`，这台机器从未进过空间）、
    /// 载入期间世界状态前进（`world_authority_activation_failed`）。
    /// 这三种都不是"用户偏好播放器"，所以默认路径**有界重试**到进空间为止；
    /// 显式的用户选择（已有 worldSession 时切换世界）不在这里重试。
    private static let startupSpaceAttemptLimit = 4
    private static let startupSpaceRetryDelay = Duration.milliseconds(1500)
    private var startupSpaceAttempts = 0
    private var startupSpaceRetryTask: Task<Void, Never>?
    private var marbleRuntimeReady = false
    private lazy var marbleRegistration: UnityMarbleAuthorityRegistration = {
        let endpoint = WorldAuthorityEndpoint(applicationSupportBase: root)
        return UnityMarbleAuthorityRegistration(services: { worldID in
            .init(client: WorldAuthorityClient(worldID: worldID, endpointFile: endpoint.endpointFile,
                helperPath: endpoint.helperPath, allowsLaunching: true))
        })
    }()
    private lazy var marbleWorlds: UnityMarbleWorldBridge = {
        let endpoint = WorldAuthorityEndpoint(applicationSupportBase: root)
        let authority = RustMarbleControlClient(endpointFile: endpoint.endpointFile,
            helperPath: endpoint.helperPath, allowsLaunching: true,
            owner: "marble.worlds", hostSessionID: nativeHostSessionID)
        let blobRoot = WorldAuthorityEndpoint.taskServiceRoot(applicationSupportBase: root).appendingPathComponent("blobs", isDirectory: true)
        return UnityMarbleWorldBridge(root: root, authority: authority, blobRoot: blobRoot, services: nil,
        runtimeReady: { [weak self] in self?.marbleRuntimeReady == true && self?.closed == false },
        register: { [weak self] package in
            guard let self, !self.closed else { throw CancellationError() }
            return try await self.registerMarblePackage(package)
        }, onRegistered: { [weak self] package in self?.spaceLibrary.registerPackage(package) ?? false })
    }()
    private lazy var spaceLibrary: UnitySpaceLibraryBridge = UnitySpaceLibraryBridge(registeredPackageRoots: registeredWorldRoots(), defaults: defaults,
        selectedWorldID: { [weak self] in self?.worldSession?.context.state.worldID },
        requestSelection: { [weak self] package, revision in self?.prepareWorldSelection(package, revision: revision) ?? false },
        productDefaults: productDefaults,
        livingPodWorldID: (try? LivingWorldBootstrap.loadBundledCanary(preferMarble: true))?.manifest.worldID,
        marble: marbleWorlds, settings: productSettings.authority)
    private func registerMarblePackage(_ package: BundledLivingWorldPackage) async throws -> Bool {
        try await marbleRegistration.register(package)
    }
    private var deviceTemplates: [[String: Any]] = []
    private var devicePlacement: UnityDevicePlacementBridge?
    func enqueueDevicePlacement(_ data: Data) -> Bool { devicePlacement?.enqueue(data) ?? false }
    private var generationConfiguration: UnityGenerationConfigurationBridge?
    private lazy var screenVideo = UnityScreenVideoBridge(defaults: defaults,
        state: { [weak self] in self?.worldSession?.context.state },
        displayName: { [weak self] id in
            let object = self?.worldSession?.context.state.objectStates[id]
            return object?.generatedProp?.displayName ?? object?.metadata["displayName"] ?? id
        }, videoAuthority:RustStageVideoClient(
            endpointFile:WorldAuthorityEndpoint(applicationSupportBase:root).endpointFile,
            helperPath:WorldAuthorityEndpoint(applicationSupportBase:root).helperPath,
            allowsLaunching:true,scope:"stage.videos",hostSessionID:nativeHostSessionID), currentTrack: { [weak self] in
            guard let self, !self.closed, let actualTrack = self.player.track else { return nil }
            let id: String
            if self.libraryQueueActive, let libraryTrack = self.libraryTrack { id = libraryTrack.id }
            else if self.queue.indices.contains(self.queueIndex) { id = self.queue[self.queueIndex].url.path }
            else { return nil }
            let slot = self.djProgram.store.activeSlot
            let cue = slot.flatMap { $0.track.id == id ? ProgramVisualDirector().cue(for: $0) : nil }
                ?? ProgramVisualDirector().cue(for: .build)
            return UnityScreenVideoBridge.CurrentTrack(id: id,
                title: self.libraryQueueActive ? self.libraryTrack?.title ?? actualTrack.title : actualTrack.title, cue: cue)
        }, mediaCache: ScreenMediaCacheClient(endpointFile:
            URL(fileURLWithPath: WorldAuthorityEndpoint(applicationSupportBase: root).endpointFile)),
        playbackAuthority: RustScreenPlaybackClient(endpointFile:
            URL(fileURLWithPath: WorldAuthorityEndpoint(applicationSupportBase: root).endpointFile)))
    private var residentMusicActions: UnityMusicRadioActions?
    private var generatedAssets: UnityGeneratedAssetCatalog?
    private var wishOutputPreview: UnityWishOutputPreviewCatalog?
    private var residentAutonomy: UnityResidentAgentLoopBridge?
    private var inboxAgent: UnityResidentInboxAgent?
    private var worldEditing = false
    private var worldEditingRevision: UInt64 = 0
    private var autonomousRunID: UUID?
    private var autonomousReplyRevision: UInt64 = 0
    private var autonomousReplies: [[String: Any]] = []
    private var pausedPosition: TimeInterval?
    private var characterSelection: [String: Any] = [:]
    private var characterSelectionRevision: UInt64 = 0
    private var characterRuntimeRevision: UInt64 = 0
    private var renderedCharacterEngine: PresenceEngine?
    private var renderedCharacterAssetID: String?
    private var renderedCharacterSelectionRevision: UInt64 = 0
    private var uiIntentRevision: UInt64 = 0
    private var uiIntents: [[String: Any]] = []
    private lazy var shortcutSettings = UnityShortcutSettingsBridge(defaults: defaults, settings: productSettings.authority) { [weak self] action in
        self?.performShortcut(action)
    }
    private lazy var presenceSettings = UnityPresenceSettingsBridge(defaults: defaults,
        packages: PresencePackageStore(rootURL: root.appendingPathComponent("gmgn radio/PresencePackages", isDirectory: true)),
        motions: MotionPackageStore(rootURL: root.appendingPathComponent("gmgn radio/MotionPackages", isDirectory: true)),
        supportedEngines: ["orb", "pmx", "vrm"],
        productSettings: productSettings.authority,
        onRuntimeChanged: { [weak self] snapshot in self?.publishCharacterSelection(snapshot) })
    private lazy var agentConnection: UnityAgentConnectionBridge = UnityAgentConnectionBridge(
        backends: { [unowned self] in chat.installedBackendSnapshot },
        currentBackend: { [unowned self] in chat.backend },
        selectBackend: { @MainActor [unowned self] id in
            guard !closed else { return false }
            guard chat.installedBackendSnapshot.contains(where: { $0["id"] as? String == id }) else { return false }
            if productSettings.authority.confirmed?.values.agentBackend == id, chat.backend == id { return true }
            do {
                _ = try await productSettings.authority.apply(["agentBackend": id])
                guard !closed, chat.selectBackend(id) else { return false }
                bindResidentSchedulerIfRequested(); agentConnection.refresh()
                return true
            } catch {
                // A missing HTTP receipt does not prove that the CAS write failed.
                // Read the authority once; never replay the settings mutation.
                do { try await productSettings.authority.reload() } catch { return false }
                guard !closed, productSettings.authority.confirmed?.values.agentBackend == id,
                      chat.selectBackend(id) else { return false }
                bindResidentSchedulerIfRequested(); agentConnection.refresh()
                return true
            }
        })
    private struct QueueEntry: Codable {
        let url: URL
        let lyricURL: URL?
    }
    private var queue: [QueueEntry] { musicPlayback.items(mode: "local", as: QueueEntry.self) }
    private var queueIndex: Int { musicPlayback.state?.mode == "local" ? musicPlayback.state?.index ?? 0 : 0 }
    private lazy var pushToTalk = UnityPushToTalkBridge(root: root,
        configuration: { [unowned self] in productSettings.voiceConfiguration(for: "asr") },
        preferredDeviceID: { [unowned self] in productSettings.microphoneDeviceID },
        submitTranscript: { _ in })

    init(root: URL, defaults suppliedDefaults: UserDefaults) throws {
        let defaults: UserDefaults
        let voiceDefaults: UserDefaults?
        if let suite = ProcessInfo.processInfo.environment["GMGN_UNITY_TEST_SETTINGS_SUITE"] {
            let prefix = "ai.gmgn.unity-sample.chat2."
            guard suite.hasPrefix(prefix), UUID(uuidString: String(suite.dropFirst(prefix.count))) != nil,
                  let isolated = UserDefaults(suiteName: suite) else {
                throw NSError(domain: "UnityMediaHost", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "invalid_test_settings_suite"])
            }
            defaults = isolated
            voiceDefaults = isolated
            productDefaults = isolated
        } else {
            defaults = suppliedDefaults
            voiceDefaults = UserDefaults(suiteName: "ai.gmgn.radio")
            productDefaults = UserDefaults(suiteName: ProductIdentity.bundleIdentifier)
        }
        self.root = root
        self.defaults = defaults
        UnityWindowModeBridge.shared.defaults = defaults
        productSettings = UnityProductSettings(root: root, defaults: defaults,
            productVoiceDefaults: voiceDefaults)
        lyricsStore = StageLyricsStore(defaults: defaults, settings: productSettings.authority)
        visualDirection = StageVisualDirectionStore(defaults: defaults, settings: productSettings.authority)
        let pointerHostSessionID = nativeHostSessionID
        world = UnityWorldBridge(root: root, propIdentity: { worldID in
            guard !worldID.isEmpty, worldID.utf8.count <= 128 else { return nil }
            return RustWorldPropClient.Identity(worldID: worldID, residentScope: "unity.ui." + worldID,
                hostSessionID: pointerHostSessionID)
        })
        let providedLibrary = ProcessInfo.processInfo.environment["GMGN_UNITY_MUSIC_LIBRARY_ROOT"].map { URL(fileURLWithPath: $0).appendingPathComponent("music-library.json") }
        musicStorage = MusicStorageClient(supportRoot: root,
            helperURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gmgn-taskd"),
            legacyFiles: (providedLibrary.map { [$0] } ?? []) + [
                root.appendingPathComponent("gmgn radio/DJPrograms/unity-dj-programs.json"),
                root.appendingPathComponent("music-library.json")])
        musicPlayback = RustMusicPlaybackClient(root: root)
        musicLibrary = UnityMusicLibraryBridge(root: root, storage: musicStorage, playbackClient: musicPlayback)
        graph = AudioGraphController(visualStore: features)
        if ProcessInfo.processInfo.environment["GMGN_UNITY_TEST_MUTED"] == "1" {
            graph.musicVolume = 0
        }
        player = LocalMusicPlayer(graph: graph)
        chat = try RenderHostResidentConversation(backend: "dsh", dataRoot: root, defaults: defaults, productSettings: productSettings.authority)
        chatImageDrop.configure(onFileURLs: { [weak self] urls in
            guard let self, !self.closed else { return }
            _ = self.chatImages.addDroppedImages(urls: urls)
        }, onBitmap: { [weak self] data in
            guard let self, !self.closed else { return }
            _ = self.chatImages.addDroppedImage(data: data)
        })
        productSettings.onSpeechPlaybackChanged = { [weak graph] playing in
            graph?.setResidentSpeechPlaying(playing)
        }
        startExistingWorldSession()
        chat.setReplySpeechProvider { [weak self] in self?.productSettings.autoSpeakReplies ?? false }
        chat.setMusicStateProvider { [weak self] in
            guard let self, !self.closed else { return ["hasTrack": false] }
            return ["hasTrack": self.player.track != nil,
                    "title": self.libraryTrack?.title ?? self.player.track?.title ?? "",
                    "artist": self.libraryTrack?.artist ?? "",
                    "trackID": self.libraryTrack?.id ?? "",
                    "provider": self.libraryTrack?.providerID.rawValue ?? "local",
                    "isPlaying": self.player.isGraphPlaying,
                    "position": self.pausedPosition ?? self.player.playbackPosition,
                    "duration": self.player.track?.duration ?? 0,
                    "queueIndex": self.libraryQueueActive ? self.musicLibrary.index : self.queueIndex,
                    "queueCount": self.libraryQueueActive ? self.musicLibrary.queue.count : self.queue.count]
        }
        musicPlayback.onError = { [weak self] error in self?.notice = error.localizedDescription }
        musicPlayback.onCommitRejected = { [weak self] ticket in
            guard let self, self.nativeMusicRequestID == ticket.requestID else { return }
            self.player.stop()
        }
        musicPlayback.onCommitted = { [weak self] in self?.didCommitMusicPlayback() }
        musicLibrary.onPrepared = { [weak self] url, lyrics, candidate in
            guard let self, !self.closed else { return false }
            do {
                // Validate the file before the shared graph stops its old node.
                _ = try AVAudioFile(forReading: url)
                try self.player.load(url)
                self.nativeMusicRequestID = self.musicPlayback.state?.pending?.requestID
                try self.player.play()
                self.session &+= 1; self.pausedPosition = nil
                self.lyricsStore.clear(); self.lines = []; self.lyricRevision &+= 1
                self.libraryTrack = candidate
                self.musicQueueRevision &+= 1
                if let lyrics {
                    self.lyricsStore.publish(lyrics, trackID: candidate.id, trackDuration: candidate.duration)
                    self.lines = self.lyricsStore.lines; self.lyricRevision &+= 1
                }
                return true
            } catch { self.notice = "这首歌未能开始播放，请选择另一首重试。"; return false }
        }
        musicLibrary.onToolPrepared = { [weak self] url, lyrics, candidate in
            guard let self, !self.closed else { return false }
            do {
                _ = try AVAudioFile(forReading: url)
                try self.player.load(url)
                self.nativeMusicRequestID = self.musicPlayback.state?.pending?.requestID
                self.session &+= 1; self.pausedPosition = 0
                self.lyricsStore.clear(); self.lines = []; self.lyricRevision &+= 1
                self.libraryTrack = candidate
                self.musicQueueRevision &+= 1
                if let lyrics {
                    self.lyricsStore.publish(lyrics, trackID: candidate.id, trackDuration: candidate.duration)
                    self.lines = self.lyricsStore.lines; self.lyricRevision &+= 1
                }
                return true
            } catch { self.notice = error.localizedDescription; return false }
        }
        musicLibrary.onProgramPrepared = { [weak self] url, lyrics, candidate in
            guard let self, !self.closed else { throw CancellationError() }
            guard self.musicLibrary.onPrepared?(url, lyrics, candidate) == true,
                  self.player.isGraphPlaying else { throw DJAgentMusicLibraryError.unsupported }
            _ = try await self.player.confirmPlaybackProgress()
        }
        musicLibrary.onProgramSlotCommitted = { [weak self] index in
            guard let self, !self.closed else { throw CancellationError() }
            try await self.djProgram.activateSlot(at: index)
        }
        musicLibrary.onProgramPlaybackReleased = { [weak self] in self?.djProgram.releasePlayback() }
        Task { [weak self] in
            guard let self, !closed else { return }
            do {
                try await productSettings.authority.ensureLoaded()
                guard !closed else { return }
                // Presence's read-only transport cannot launch taskd. Restore
                // only after this same authority has confirmed helper readiness.
                presenceSettings.load()
                guard let backend = productSettings.authority.confirmed?.values.agentBackend else { return }
                _ = chat.selectBackend(backend); agentConnection.refresh()
            } catch { /* No legacy candidate is promoted. */ }
        }
        agentConnection.refresh()
        shortcutSettings.start()
        savedProgramRestoreTask = Task { [weak self] in
            guard let self, !self.closed else { return }
            do { _ = try await self.djProgram.restoreSavedPlayback() }
            catch is CancellationError { }
            catch { if !self.closed { self.notice = error.localizedDescription } }
            self.savedProgramRestoreTask = nil
        }
        residentAutonomy?.start()
    }

    private func performShortcut(_ action: GMGNShortcutAction) {
        guard !closed else { return }
        switch action {
        case .togglePlayback: _ = command(["op": player.isGraphPlaying ? "music.pause" : "music.play"])
        case .previousTrack: _ = command(["op": "music.previous"])
        case .nextTrack: _ = command(["op": "music.next"])
        case .volumeUp: _ = command(["op": "music.volume", "value": Double(min(1, graph.musicVolume + 0.05))])
        case .volumeDown: _ = command(["op": "music.volume", "value": Double(max(0, graph.musicVolume - 0.05))])
        case .toggleVoice, .toggleStage, .toggleLyrics:
            uiIntentRevision &+= 1
            uiIntents.append(["revision": uiIntentRevision, "action": action.rawValue])
        }
    }

    private func makeResidentMusicActions() -> UnityMusicRadioActions {
        UnityMusicRadioActions(hooks: .init(playback: { [unowned self] in
            let tracks = musicLibrary.queue.map { candidate in
                UnityMusicRadioActions.Track(id: candidate.id, provider: candidate.providerID.rawValue,
                    title: candidate.title, artist: candidate.artist, album: candidate.album, duration: candidate.duration)
            }
            let localTracks = queue.enumerated().map { index, entry in
                UnityMusicRadioActions.Track(id: entry.url.path, provider: "local",
                    title: index == queueIndex ? player.track?.title ?? entry.url.deletingPathExtension().lastPathComponent : entry.url.deletingPathExtension().lastPathComponent,
                    artist: "", album: nil, duration: index == queueIndex ? player.track?.duration ?? 0 : 0)
            }
            let local = player.track.map { UnityMusicRadioActions.Track(id: queue.indices.contains(queueIndex) ? queue[queueIndex].url.path : $0.title,
                provider: "local", title: $0.title, artist: "", album: nil, duration: $0.duration) }
            return .init(track: libraryQueueActive && tracks.indices.contains(musicLibrary.index) ? tracks[musicLibrary.index] : local,
                queue: libraryQueueActive ? tracks : localTracks,
                index: libraryQueueActive ? musicLibrary.index : (local == nil ? nil : queueIndex),
                position: pausedPosition ?? player.playbackPosition, isPlaying: player.isGraphPlaying)
        }, command: { [unowned self] action in
            guard !closed else { throw CancellationError() }
            switch action {
            case .pause: player.pause(); pausedPosition = player.playbackPosition
            case .resume: try player.play(); pausedPosition = nil
            case .next, .previous:
                if libraryQueueActive {
                    _ = try await musicLibrary.toolNavigate({ if case .next = action { return 1 }; return -1 }())
                    try player.play(); pausedPosition = nil
                } else {
                    guard command(["op": { if case .next = action { return "music.next" }; return "music.previous" }()]) else { throw DJAgentMusicLibraryError.unsupported }
                }
            case let .play(trackID, slotIndex):
                if trackID != nil || slotIndex != nil {
                    let ticket = try musicPlayback.navigate(slotIndex: slotIndex, trackID: trackID)
                    if ticket.mode == "library" { _ = try await musicLibrary.toolSelect(ticket.index) }
                    else { try loadQueueEntry(ticket, autoplay: false) }
                }
                try player.play(); pausedPosition = nil
            case let .lyrics(mode):
                guard command(["op": "stage.player.lyrics", "id": mode.agentValue]) else { throw DJAgentMusicLibraryError.unsupported }
            case let .mood(mood): visualDirection.update(mood)
            }
        }, search: { [unowned self] in try await musicLibrary.toolSearch(query: $0, limit: $1) },
           list: { [unowned self] in try await musicLibrary.toolList(query: $0, offset: $1, limit: $2) },
           read: { [unowned self] in try await musicLibrary.toolRead(playlistID: $0, offset: $1, limit: $2) },
           prepare: { [unowned self] in try await musicLibrary.toolPrepare(playlistID: $0, trackID: $1) },
           spatialEnvironment: { [weak self] scene, weather in
               guard let self, !self.closed else { throw CancellationError() }
               try await self.setSpatialEnvironment(scene: scene, weather: weather)
           }, spatialCamera: { [weak self] direction, distance in
               guard let self, !self.closed else { throw CancellationError() }
               try await self.spatialPresentation.moveCamera(direction: direction, distance: distance)
           }), program: djProgram)
    }
    private func installWorldSession(_ composition: UnityWorldSessionComposition, selectedWorldID: String) {
        characterPosition?.close()
        inboxAgent?.close(); inboxAgent = nil
        worldSession = composition
        // 进到空间之后，启动落空间的尝试计数回到零：它是"这一轮启动"的上界，不是
        // 整个会话的终身额度。不归零的话，之后任何一次切换空间的抖动都会发现自己
        // 的额度已经被上一次启动用光了（`scheduleStartupSpaceRetry` 的第一道守卫）。
        startupSpaceAttempts = 0
        startupSpaceRetryTask?.cancel(); startupSpaceRetryTask = nil
        let spawn = composition.context.manifest.spawn.position
        func positionState(_ state: WorldState, movement: String?) -> UnityCharacterPositionBridge.State {
            let p = state.agentTransform.position
            return .init(worldID: state.worldID, revision: state.revision, layoutRevision: state.layoutRevision,
                         position: [Double(p.x), Double(p.y), Double(p.z)], movementRequestID: movement)
        }
        characterPosition = UnityCharacterPositionBridge(worldID: selectedWorldID,
            spawn: [Double(spawn.x), Double(spawn.y), Double(spawn.z)],
            state: { positionState(composition.context.state, movement: composition.context.currentMovementRequestID) },
            move: { [weak self, weak composition] xyz, requestID, revision in
                guard let self, let composition, !self.closed, self.worldSession === composition else { throw CancellationError() }
                let path = try composition.context.move(to: WorldVector3(x: Float(xyz[0]), y: Float(xyz[1]), z: Float(xyz[2])),
                                                        requestID: requestID, expectedRevision: revision)
                guard let target = path.points.last else { throw WorldCoordinateMovementError.blocked }
                return [Double(target.x), Double(target.y), Double(target.z)]
            }, durableReadback: { [weak self, weak composition] in
                guard let self, let composition, !self.closed, self.worldSession === composition,
                      let saved = try await composition.context.readAuthoritySnapshot() else { throw CancellationError() }
                guard !self.closed, self.worldSession === composition else { throw CancellationError() }
                return positionState(saved, movement: nil)
            })
        if let engine = renderedCharacterEngine {
            composition.updateCharacterFormat(engine, assetID: renderedCharacterAssetID,
                selectionRevision: renderedCharacterSelectionRevision)
        }
        installWishOutputPreview(composition, worldID: selectedWorldID)
        generatedAssets = UnityGeneratedAssetCatalog(root: root, worldID: selectedWorldID, residentScope: composition.residentScope)
        let synchronizeJobs = composition.generationStore.onChange
        composition.generationStore.onChange = { [weak self, weak composition] in
            synchronizeJobs?()
            guard let self, let composition, self.worldSession === composition else { return }
            self.refreshGeneratedCatalog()
        }
        composition.wish.onInventoryConfirmed = { [weak self, weak composition] _ in
            Task { @MainActor in
                guard let self, let composition, !self.closed, self.worldSession === composition else { return }
                do {
                    _ = try await composition.refreshAuthorityState(preservingActorForInventory: true)
                    guard self.worldSession === composition else { return }
                    self.refreshGeneratedCatalog()
                    _ = self.world.command(["op": "world.snapshot", "worldID": selectedWorldID])
                } catch { self.notice = error.localizedDescription }
            }
        }
        refreshGeneratedCatalog()
        composition.context.onActivityStopped = { [weak self, weak composition] in
            guard let self, let composition, !self.closed,
                  self.worldSession === composition else { return }
            _ = self.presenceSettings.stopSelectedMotion()
        }
        composition.onPropLayoutChanged = { [weak self, weak composition] in
            guard let self, let composition, self.worldSession === composition else { return }
            self.refreshGeneratedCatalog()
            _ = self.world.command(["op": "world.snapshot", "worldID": selectedWorldID])
        }
        generationConfiguration = UnityGenerationConfigurationBridge(store: composition.generationStore,
            authority: RustGenerationConfigurationClient(root: root.appendingPathComponent("TaskService")),
            fileURL: root.appendingPathComponent("secrets/prop-generation.json"),
            readableLegacyFileURL: PropGenerationConfigurationStore.defaultFileURL)
        deviceTemplates = UnityBuiltinDevicesBridge.snapshot(worldID: selectedWorldID)
        let placement = UnityDevicePlacementBridge(root: root, worldID: selectedWorldID, templates: deviceTemplates, worldBridge: world)
        placement.onCommitted = { [weak self, weak composition] _ in
            Task { @MainActor in
                guard let self, let composition, !self.closed, self.worldSession === composition else { return }
                do {
                    _ = try await composition.refreshAuthorityState()
                    guard !self.closed, self.worldSession === composition else { return }
                    self.refreshGeneratedCatalog()
                    _ = self.world.command(["op": "world.snapshot", "worldID": selectedWorldID])
                } catch { self.notice = error.localizedDescription }
            }
        }
        devicePlacement = placement
        composition.prepareJukebox = { [weak self, weak composition, weak placement] in
            guard let self, let composition, let placement, !self.closed,
                  self.worldSession === composition else { throw CancellationError() }
            let requestID = "jukebox-functions:" + UUID().uuidString
            let refresh = try await Task.detached {
                try await placement.refreshJukeboxFunctions(requestID: requestID)
            }.value
            guard !self.closed, self.worldSession === composition else { throw CancellationError() }
            // A formal no-op read must not restore an older durable simulation
            // over the current volatile revision/phase and renderer lease.
            guard refresh.didCommit else { return }
            // The device client is a different CAS owner. Adopting its state
            // alone leaves the resident persistence lease at its old revision.
            // Reload through the context's owner before the next checkpoint.
            _ = try await composition.refreshAuthorityState()
        }
        let musicActions = makeResidentMusicActions()
        residentMusicActions = musicActions
        let services = composition.worldServices(musicActions: musicActions, musicPlanningAvailable: true, spatialActionsAvailable: true,
            musicTakeoverEnabled: { [weak self] in self?.djPreferences.takeoverEnabled() ?? false },
            screenCapability: { [weak self] objectID in
            self?.screenVideo.propCapability(objectID: objectID)
        }, serviceFacts: { [weak self] in
            let state = self?.generationConfiguration?.snapshot ?? [:]
            return (state["configured"] as? Bool == true, state["noticeCode"] as? String ?? "generation_not_configured")
        })
        services.dispatcher.availableMotions = { [weak self, weak composition] in
            guard let self, let composition, !self.closed, self.worldSession === composition else { return [] }
            return self.presenceSettings.agentMotions
        }
        services.dispatcher.selectMotion = { [weak self, weak composition] id in
            guard let self, let composition, !self.closed, self.worldSession === composition,
                  self.presenceSettings.canSelectMotion(id) else { return false }
            do { try composition.prepareManualMotionSelection() }
            catch { return false }
            // The stop `prepareManualMotionSelection` just began is *this* host's
            // own preparation for the selection below. Waiting for it (bounded by
            // the gate's own budget) is what keeps that stop from refusing the
            // selection it was preparing: 2026-10-09 build 229 answered the user's
            // click `side=bridge op=presence.motion.stop ageMs=0`.
            await self.presenceSettings.awaitSelectionPreparation()
            return self.presenceSettings.command(["op": "presence.motion", "id": id])
        }
        let autonomy = UnityResidentAgentLoopBridge(context: composition.context, defaults: defaults, settings: productSettings.authority,
            available: { [weak self, weak composition] in
                guard let self, let composition, !self.closed,
                      self.worldSession === composition else { return false }
                return self.chat.installedBackendSnapshot.contains {
                    $0["id"] as? String == self.chat.backend && $0["installed"] as? Bool == true
                }
            }, run: { [weak self, weak composition] input in
                guard let self, let composition, !self.closed, self.worldSession === composition else { throw CancellationError() }
                self.autonomousRunID = input.runID
                defer { if self.autonomousRunID == input.runID { self.autonomousRunID = nil } }
                do {
                    let persistedScheduler = self.residentAutonomy?.usesRustScheduler == true
                    let reply = try await self.chat.runBackground(input: input, preserveActualCompletion: persistedScheduler,
                        rustClaim: self.residentAutonomy?.loop.claimedRustBinding(runID: input.runID))
                    if persistedScheduler && (Task.isCancelled || self.closed || self.worldSession !== composition) {
                        // Preserve the real result for its original durable claim,
                        // without consuming current-world events or showing stale UI.
                        return reply
                    }
                    try Task.checkCancellation()
                    guard !self.closed, self.worldSession === composition else { throw CancellationError() }
                    guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || self.residentAutonomy?.loop.allowsSilentCompletion(runID: input.runID) == true else {
                        throw NSError(domain: "GMGNResidentTurn", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "居民本轮没有返回内容或安排等待"])
                    }
                    composition.didConsumeWishEvents(input.events)
                    try await self.inboxAgent?.complete(events: input.events, runID: input.runID)
                    return reply
                } catch {
                    composition.didNotConsumeWishEvents(input.events)
                    self.inboxAgent?.failed(events: input.events, runID: input.runID)
                    throw error
                }
            }, cancelRun: { [weak self] in
                guard let self, let id = self.autonomousRunID else { return }
                _ = self.chat.cancelRun(runID: id)
                self.autonomousRunID = nil
            }, onReply: { [weak self] text in
                guard let self, !self.closed else { return }
                self.autonomousReplyRevision &+= 1
                self.autonomousReplies.append(["revision": self.autonomousReplyRevision, "text": text])
                self.autonomousReplies = Array(self.autonomousReplies.suffix(24))
                let source = self.chat.lastReplySpeechSource
                if let runID = source["runID"] as? String {
                    let requestID = "world-run:" + runID
                    self.productSettings.replySpeechEvent(requestID: requestID, kind: "accepted")
                    self.productSettings.replySpeechEvent(requestID: requestID, kind: "reply", source: source)
                }
            })
        residentAutonomy = autonomy
        composition.context.onRustEventsPublished = { [weak self, weak composition, weak autonomy] events in
            guard let self, let composition, let autonomy, !self.closed,
                  self.worldSession === composition, self.residentAutonomy === autonomy else { return }
            for event in events {
                if let observation = ResidentWorldObservation.event(event,
                    worldID: composition.context.manifest.worldID, scopeID: "", authorityFact: true) {
                    autonomy.receive(observation)
                }
            }
        }
        autonomy.humanRun = { [weak self, weak composition] input in
            guard let self, let composition, self.worldSession === composition,
                  let pending = self.scheduledHumanSubmission, pending.session === composition,
                  input.userMessages == [pending.submission.text],
                  input.imageURLs == pending.submission.attachments.map(\.url) else { throw CancellationError() }
            defer {
                if self.scheduledHumanSubmission?.submission.id == pending.submission.id {
                    self.scheduledHumanSubmission = nil
                }
            }
            return try await withCheckedThrowingContinuation { continuation in
                let accepted = self.chat.send(requestID: pending.requestID, submission: pending.submission,
                    authorizeImages: { [weak self, weak composition] runID, isCurrent in
                        guard let self, let composition, self.worldSession === composition, isCurrent() else { throw CancellationError() }
                        try await composition.authorizeHumanImages(runID: runID, conversationID: self.humanImageConversationID,
                            attachments: pending.submission.attachments, isCurrent: isCurrent)
                    }, executionRunID: input.runID,
                    rustClaim: self.residentAutonomy?.loop.claimedRustBinding(runID: input.runID),
                    actualCompletion: { result in continuation.resume(with: result) })
                if !accepted {
                    continuation.resume(throwing: NSError(domain: "GMGNResidentTurn", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "人类消息未开始执行，输入已保留。 "]))
                }
            }
        }
        autonomy.humanCancel = { [weak self] in
            guard let self, let pending = self.scheduledHumanSubmission else { return }
            if !self.chat.cancel(requestID: pending.requestID) {
                self.chat.cancelUnstarted(requestID: pending.requestID, submission: pending.submission)
                if self.scheduledHumanSubmission?.submission.id == pending.submission.id { self.scheduledHumanSubmission = nil }
            }
        }
        bindResidentSchedulerIfRequested()
        let inboxClient = ResidentStateClient(transport: ResidentTaskDaemonStateTransport(client:
            PropTaskDaemonClient(root: root.appendingPathComponent("gmgn radio/TaskService", isDirectory: true),
                allowsLaunching: false)))
        let agentInbox = UnityResidentInboxAgent(client: inboxClient,
            scope: .init(worldID: selectedWorldID, residentScope: composition.residentScope),
            submit: { [weak self, weak composition, weak autonomy] event in
                guard let self, let composition, let autonomy, !self.closed,
                      self.worldSession === composition, self.residentAutonomy === autonomy,
                      !self.worldEditing, !autonomy.loop.snapshot.isStopped,
                      !autonomy.loop.snapshot.intentPausedByUser,
                      !autonomy.loop.snapshot.isRunning else { return false }
                return autonomy.receiveWish(event, continuation: true)
            })
        inboxAgent = agentInbox
        composition.bindWishAgent { [weak self, weak composition, weak autonomy] event, continuation in
            guard let self, let composition, let autonomy, !self.closed,
                  self.worldSession === composition, self.residentAutonomy === autonomy else { return false }
            return autonomy.receiveWish(event, continuation: continuation)
        }
        chat.setWorldServices(.init(context: services.context, dispatcher: services.dispatcher,
            isCurrent: services.isCurrent, additionalTools: { [weak self] runID, text, isCurrent in
                services.additionalTools(runID, text, isCurrent) + (self?.screenTools(isCurrent: isCurrent) ?? [])
                    + UnityInboxAgentTools.tools(inbox: composition.inbox, isCurrent: isCurrent,
                        didRead: { [weak agentInbox] entries in agentInbox?.noteRead(entries: entries, runID: runID) })
            }, onCancel: services.onCancel,
            backgroundTools: { [weak self] runID, isCurrent in
                guard let self, let autonomy = self.residentAutonomy, isCurrent() else { return [] }
                let tools = autonomy.tools(runID: runID)
                return ResidentLoopTools.schemas.compactMap { schema in
                    guard let name = schema["name"] as? String,
                          let description = schema["description"] as? String,
                          let input = schema["inputSchema"] as? [String: Any] else { return nil }
                    return ResidentWorldToolSession.AdditionalTool(name: name, description: description,
                        inputSchema: input, validate: { _ in isCurrent() }, handle: { callID, data in
                            let result = await tools.handle(name: name, argumentsJSON: data)
                            return .init(callID: callID, resultJSON: result.data, isError: result.isError)
                        })
                } + services.backgroundTools(runID, isCurrent) + self.screenTools(isCurrent: isCurrent)
                    + UnityInboxAgentTools.tools(inbox: composition.inbox, isCurrent: isCurrent,
                        didRead: { [weak agentInbox] entries in agentInbox?.noteRead(entries: entries, runID: runID) })
            }), preservingActiveReply: spatialSceneTransitionInProgress && spatialSceneSelectionRevision != nil
                && spatialSceneSelectionRevision == worldSelection["revision"] as? UInt64)
        composition.start()
        agentInbox.start()
    }
    private func registeredWorldRoots() -> [URL] {
        var roots: [URL] = []
        roots += UnityMarblePackageBuilder.registeredRoots(root: root)
        if let bundled = try? LivingWorldBootstrap.loadBundledCanary() { roots.append(bundled.packageRoot) }
        if let resources = Bundle.main.resourceURL {
            let parent = resources.appendingPathComponent("Worlds", isDirectory: true)
            roots += (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        }
        // Explicit paths only; cached Marble downloads are not world packages.
        if let supplied = ProcessInfo.processInfo.environment["GMGN_UNITY_REGISTERED_WORLD_PACKAGES"] {
            roots += supplied.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        }
        return roots
    }
    private func startExistingWorldSession() {
        // World availability cannot abort the independent audio/chat host.
        // Match formal packages to actual Rust records, never seed a canary to
        // conceal a missing endpoint or replace the user's existing space.
        let preferred = [ProcessInfo.processInfo.environment["GMGN_UNITY_WORLD_ID"]].compactMap { $0 }
            + spaceLibrary.startupSelectionIDs()
        var seen = Set<String>()
        let candidates = preferred.filter { seen.insert($0).inserted }.compactMap { spaceLibrary.package(for: $0) }
        // Observable even when the engine has not yet serviced the Swift main
        // executor; an empty projection cannot distinguish that from no world.
        worldSelection = ["revision": UInt64(0), "phase": "starting", "candidateCount": candidates.count]
        NSLog("[UnityMediaHost] world startup scheduled: candidates=%ld", candidates.count)
        worldSelectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var failureCode = "world_package_missing"
            for package in candidates {
                do {
                    let id = package.manifest.worldID
                    worldSelection = ["revision": UInt64(0), "worldID": id, "phase": "reading"]
                    NSLog("[UnityMediaHost] world startup authority read: world=%@", id)
                    let endpoint = WorldAuthorityEndpoint(applicationSupportBase: root)
                    let client = WorldAuthorityClient(worldID: id, endpointFile: endpoint.endpointFile,
                        helperPath: endpoint.helperPath, allowsLaunching: true)
                    var record = try await Task.detached(priority: .utility) { try client.snapshot() }.value
                    try Task.checkCancellation()
                    guard !closed else { return }
                    // 没有用户偏好/这台机器还没进过空间：权威里没有这个世界的记录。
                    // 把只读预像**一次性**导入（与用户显式选空间走的是同一条导入），
                    // 默认路径就能落在空间，而不是因为没有偏好就退回播放器。
                    // 已有记录时 load() 只读、不覆盖；没有预像时不凭空造世界。
                    if record == nil, importDefaultSpaceRecord(package: package, endpoint: endpoint) {
                        record = try await Task.detached(priority: .utility) { try client.snapshot() }.value
                        try Task.checkCancellation()
                        guard !closed else { return }
                    }
                    guard record != nil else { failureCode = "world_authority_record_missing"; continue }
                    // Renderer preparation must precede the single live world
                    // owner. Starting a context here advances a restored active
                    // run while the renderer loads, invalidating its readback.
                    // completeWorldSelection constructs and starts that owner
                    // only after the verified render receipt.
                    worldSelectionTask = nil
                    _ = spaceLibrary.settingsCommand(["op": "space.library.select", "id": id])
                    return
                } catch is CancellationError { return }
                catch let error as WorldAuthorityError {
                    switch error {
                    case .unavailable: failureCode = "world_authority_unavailable"
                    case .noAuthorityRecord: failureCode = "world_authority_record_missing"
                    default: failureCode = "world_authority_invalid"
                    }
                    if failureCode == "world_authority_unavailable" { break }
                } catch { failureCode = "world_package_invalid" }
            }
            guard !closed else { return }
            worldSelectionTask = nil
            if scheduleStartupSpaceRetry(failureCode: failureCode) { return }
            worldSelection = ["revision": UInt64(0), "phase": "failed", "code": failureCode,
                "message": "空间暂时无法连接，音乐和聊天仍可使用。请重新选择空间或稍后重试。"]
            NSLog("[UnityMediaHost] space startup unavailable: %@; audio/chat retained", failureCode)
        }
    }
    /// 渲染回执没来时的宿主兜底。渲染侧自己的准备预算先到期并给出具名失败；
    /// 这一层只覆盖"回执丢失/送不到"，它以前会让整个产品停在播放器上，
    /// `phase=prepare` 且任何日志里都没有具名原因。
    private func schedulePrepareWatchdog(id: String, revision: UInt64) {
        prepareWatchdogTask?.cancel()
        prepareWatchdogTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.prepareWatchdogDelay) }
            catch { return }
            guard let self, !self.closed else { return }
            guard self.worldSelection["revision"] as? UInt64 == revision,
                  self.worldSelection["worldID"] as? String == id,
                  self.worldSelection["phase"] as? String == "prepare",
                  self.pendingWorldPackage?.manifest.worldID == id else { return }
            self.prepareWatchdogTask = nil
            self.pendingWorldPackage = nil
            self.worldSelection["phase"] = "failed"
            self.worldSelection["code"] = "world_prepare_unanswered"
            self.worldSelection["message"] = "空间画面没有回应，当前空间已保留。"
            NSLog("[UnityMediaHost] world selection: world=%@ phase=failed code=world_prepare_unanswered", id)
            // 迟到的成功回执会因为 `phase != prepare` 被 `completeWorldSelection`
            // 拒绝，所以这里不会和渲染侧的成功重入打架。
            _ = self.spaceLibrary.completeSelection(revision: revision, worldID: id, success: false)
            // 回执没来也是**同一条**收口：有界重试，用尽才具名终局。
            if self.worldSession == nil {
                _ = self.retryStartupSpaceOrPublishFailure("world_prepare_unanswered")
            }
        }
    }
    /// 启动默认落空间的**有界**重试。次数与间隔都是常量：权威一直不起来时
    /// 仍然给出真实失败（日志 + 红字），只是不再一次失败就整场会话停在播放器。
    private func scheduleStartupSpaceRetry(failureCode: String) -> Bool {
        guard !closed, worldSession == nil, startupSpaceAttempts < Self.startupSpaceAttemptLimit else { return false }
        startupSpaceAttempts += 1
        let attempt = startupSpaceAttempts
        startupSpaceRetryTask?.cancel()
        startupSpaceRetryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.startupSpaceRetryDelay) }
            catch { return }
            guard let self, !self.closed, self.worldSession == nil,
                  self.worldSelectionTask == nil, self.pendingWorldPackage == nil else { return }
            NSLog("[UnityMediaHost] space startup retry %ld after %@", attempt, failureCode)
            self.startExistingWorldSession()
        }
        return true
    }
    /// 哪些启动失败值得重试。
    ///
    /// 渲染侧**自己给了条件名**的拒绝（`world_prepare_rejected`：`InvalidDataException`
    /// / `NotSupportedException` / `InvalidOperationException`，见
    /// `WorldRuntimeBridge.cs:417-421`）是确定性的——重试只会把同一句拒绝再说四遍，
    /// 还把用户看到那句红字的时间推后。其余（超时、未具名的载入失败、回执没来、
    /// 载入期间状态前进、包在载入期间变化）都是"这一次没成"的抖动，同一条有界重试
    /// 能救回来。未知的新码默认**可重试**：宁可多试一次有界次数，也不要一次抖动
    /// 就把整场会话停在播放器。
    static func startupSpaceFailureIsRetryable(_ failureCode: String) -> Bool {
        failureCode != "world_prepare_rejected"
    }
    /// **启动落空间的唯一收口**：先按 [`scheduleStartupSpaceRetry`] 有界重试；重试用尽
    /// 才把失败**具名**落到 `worldSelection`，并给出一句可操作的下一步。
    ///
    /// 为什么要收成一个口（2026-10-09 现场）：三条失败路径里只有"候选循环走完"
    /// （`:776`）和"回执没来"（`:804`）会调重试，而这次真机冷启动走的是**第四条**——
    /// 渲染侧正常回执但 `success=false`（`code=world_prepare_timeout`，
    /// `WorldRuntimeBridge.cs:410-414`）。那条路径一次失败就停在播放器，`startupSpaceAttempts`
    /// 不涨、日志里没有 `space startup retry`，而同一份资产在同一台机器上一小时前
    /// 17.1 s 就进过空间（`Player-prev.log` 19:10:46.778 → 19:11:03.885）。一次
    /// **可重试**的载入抖动因此变成了整场会话进不去。
    ///
    /// 收口的另一半同样重要：所有失败路径都必须把 `pendingWorldPackage` /
    /// `worldSelectionTask` / watchdog 清干净，否则第二次 prepare 会被
    /// `prepareWorldSelection` 自己的入口守卫（`:883`）挡掉——重试就成了空话。
    @discardableResult
    private func retryStartupSpaceOrPublishFailure(_ failureCode: String) -> Bool {
        if scheduleStartupSpaceRetry(failureCode: failureCode) { return true }
        publishStartupSpaceFailure(failureCode)
        return false
    }
    /// 有界重试**用尽**之后的终局：具名 code + 一句能照着做的下一步。
    ///
    /// 文案沿用这条链已经在用、并且已经在加载态登记表里收走的那一句
    /// （`RETIRED_COPY` 绑定到 `world.authority`）：这里不新造一句"没 ready"，
    /// 具名由 `code` 与日志行给出。
    private func publishStartupSpaceFailure(_ failureCode: String) {
        worldSelectionTask?.cancel(); worldSelectionTask = nil
        prepareWatchdogTask?.cancel(); prepareWatchdogTask = nil
        pendingWorldPackage = nil
        worldSelection = ["revision": UInt64(0), "phase": "failed", "code": failureCode,
            "message": "空间暂时无法连接，音乐和聊天仍可使用。请重新选择空间或稍后重试。"]
        NSLog("[UnityMediaHost] space startup exhausted: %@ attempts=%ld/%ld; audio/chat retained",
              failureCode, startupSpaceAttempts, Self.startupSpaceAttemptLimit)
    }
    /// 首次启动的**一次性**只读预像导入（`AuthorityWorldStatePersistence.load()`
    /// 只在权威没有记录时导入）。返回是否确实拿到了这个世界。
    ///
    /// 预像路径除了 `LivingWorldBootstrap` 自己算出来的那一条，还要按**产品身份**
    /// `ai.gmgn.radio` 再找一遍：`RenderHost` 模块编译进来的 `ProductIdentity` 是
    /// fixture 身份 `ai.gmgn.gpui-probe.render-host`，而旧的 `state.json` 预像真实
    /// 写在 `ai.gmgn.radio` 下（生产机上只有后者）。两条都找不到就**不导入**——
    /// 绝不凭空造一个世界。
    private func importDefaultSpaceRecord(package: BundledLivingWorldPackage, endpoint: WorldAuthorityEndpoint) -> Bool {
        guard let archive = try? LivingWorldBootstrap.statePersistence(manifest: package.manifest,
                                                                        applicationSupportBase: root),
              let compiledIn = try? LivingWorldBootstrap.preImageCandidateURLs(manifest: package.manifest,
                                                                              applicationSupportBase: root) else {
            NSLog("[UnityMediaHost] default space seed: no pre-image path for world=%@", package.manifest.worldID)
            return false
        }
        let candidates = compiledIn + Self.legacyProductPreImageURLs(package: package.manifest, base: root)
        let preImage = LegacyWorldStatePreImage(archive: archive, candidateURLs: candidates)
        guard preImage.rawPreImage() != nil else {
            NSLog("[UnityMediaHost] default space seed: pre-image absent for world=%@ paths=%@",
                  package.manifest.worldID, candidates.map(\.path).joined(separator: ","))
            return false
        }
        let persistence = AuthorityWorldStatePersistence(manifest: package.manifest,
            preImage: preImage, endpointFile: endpoint.endpointFile, helperPath: endpoint.helperPath)
        do {
            let state = try persistence.load()
            NSLog("[UnityMediaHost] default space seed: world=%@ state=%@", package.manifest.worldID,
                  state == nil ? "absent" : "present")
            return state != nil
        } catch {
            NSLog("[UnityMediaHost] default space seed: world=%@ failed=%@", package.manifest.worldID,
                  String(describing: type(of: error)))
            return false
        }
    }
    /// 产品自己的 Application Support 身份（`GMGNRadioApp.swift` 的 `ProductIdentity`，
    /// 也是旧 `state.json` 预像的真实位置）。按当前包版本优先、其余版本按修改时间从新到旧。
    static let legacyProductIdentity = "ai.gmgn.radio"
    static func legacyProductPreImageURLs(package: WorldManifest, base: URL,
                                          fileManager: FileManager = .default) -> [URL] {
        let directory = base
            .appendingPathComponent(legacyProductIdentity, isDirectory: true)
            .appendingPathComponent("LivingWorld", isDirectory: true)
            .appendingPathComponent(package.packageID, isDirectory: true)
        let current = directory
            .appendingPathComponent(LivingWorldBootstrap.sanitizedPackageVersionDirectory(package.packageVersion),
                                    isDirectory: true)
            .appendingPathComponent("state.json")
        let versions = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("state.json").path) }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            .map { $0.appendingPathComponent("state.json") } ?? []
        var seen = Set<String>()
        return ([current] + versions).filter { seen.insert($0.path).inserted }
    }
    private func prepareWorldSelection(_ package: BundledLivingWorldPackage, revision: UInt64) -> Bool {
        guard !closed, pendingWorldPackage == nil, worldSelectionTask == nil else { return false }
        pendingWorldPackage = package
        let id = package.manifest.worldID
        worldSelectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.worldSelectionTask = nil }
            do {
                let endpoint = WorldAuthorityEndpoint(applicationSupportBase: root)
                let client = WorldAuthorityClient(worldID: id, endpointFile: endpoint.endpointFile, helperPath: endpoint.helperPath, allowsLaunching: false)
                let record = try await Task.detached(priority: .utility) {
                    guard let record = try client.snapshot() else { throw WorldAuthorityError.noAuthorityRecord }
                    return record
                }.value
                try Task.checkCancellation()
                guard !closed, pendingWorldPackage?.manifest.worldID == id else { return }
                guard let entry = (spaceLibrary.snapshot["worlds"] as? [[String: Any]])?.first(where: { $0["id"] as? String == id }),
                      let hash = entry["manifestSHA256"] as? String else { throw WorldAuthorityError.noAuthorityRecord }
                let state = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record.state))
                let scope = "resident.world." + Data(id.utf8).base64EncodedString()
                let catalog = UnityGeneratedAssetCatalog(root: root, worldID: id, residentScope: scope)
                // A newly created store has not received its asynchronous
                // projection yet. Renderer preparation needs the actual receipt
                // snapshot now, including when switching to another world.
                let support = root.appendingPathComponent("gmgn radio", isDirectory: true)
                let tasks = PropTaskDaemonClient(root: support.appendingPathComponent("TaskService", isDirectory: true),
                    legacyRoot: support.appendingPathComponent("PropGeneration", isDirectory: true), allowsLaunching: false)
                defer { tasks.disconnect() }
                let taskSnapshot = try await tasks.snapshot()
                try Task.checkCancellation()
                guard !closed, pendingWorldPackage?.manifest.worldID == id else { return }
                try catalog.update(state: record.state, jobs: taskSnapshot.jobs, revision: record.recordRevision)
                worldSelection = ["revision": revision, "worldID": id, "packageRoot": package.packageRoot.path,
                    "manifestSHA256": hash, "phase": "prepare", "generatedAssets": catalog.snapshot(),
                    "record": ["revision": record.recordRevision, "state": state]]
                NSLog("[UnityMediaHost] world selection: world=%@ phase=prepare revision=%llu", id, revision)
                NSLog("[UnityMediaHost] world selection assets: world=%@ entries=%ld", id,
                    (catalog.snapshot()["entries"] as? [[String: Any]])?.count ?? 0)
                schedulePrepareWatchdog(id: id, revision: revision)
            } catch {
                pendingWorldPackage = nil
                worldSelection = ["revision": revision, "worldID": id, "phase": "failed",
                    "code": "world_prepare_host_failed", "message": "空间准备失败，当前空间已保留。"]
                NSLog("[UnityMediaHost] world selection: world=%@ phase=failed code=world_prepare_host_failed", id)
                _ = spaceLibrary.completeSelection(revision: revision, worldID: id, success: false)
                // 宿主这一侧的准备失败（权威读不到、清单/任务投影读不到）也是启动
                // 落空间的一次抖动：走同一条有界重试，而不是一次就停在播放器。
                if worldSession == nil { _ = retryStartupSpaceOrPublishFailure("world_prepare_host_failed") }
            }
        }
        return true
    }
    private func setSpatialEnvironment(scene: SpatialScenePreset?, weather: SpatialWeather?) async throws {
        guard !closed else { throw CancellationError() }
        try await spatialPresentation.confirmVisible()
        if let scene {
            guard !spatialSceneTransitionInProgress else { throw UnitySpatialPresentationBridge.PresentationError.busy }
            spatialSceneTransitionInProgress = true
            defer { spatialSceneTransitionInProgress = false; spatialSceneSelectionRevision = nil }
            let package = try await marbleWorlds.activatePreset(scene)
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            let id = package.manifest.worldID
            if worldSession?.context.state.worldID != id {
                guard spaceLibrary.settingsCommand(["op": "space.library.select", "id": id]),
                      let revision = spaceLibrary.snapshot["selectionRevision"] as? UInt64 else { throw UnityMarbleError.selectionRejected }
                spatialSceneSelectionRevision = revision
                try await awaitWorldActivation(id: id, revision: revision)
            }
        }
        try Task.checkCancellation()
        if scene != nil { try await spatialPresentation.confirmVisible() }
        if let weather { try await spatialPresentation.setWeather(weather) }
    }
    /// Wait for the selection transaction this host already owns to reach the
    /// renderer-verified `activate` phase. The world is not declared entered
    /// before that phase, so a timeout is never reported as success. Shared by
    /// the scene-preset path and the settings window's 进入世界/切换场景.
    private func awaitWorldActivation(id: String, revision: UInt64) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while true {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            if worldSelection["revision"] as? UInt64 == revision, worldSelection["worldID"] as? String == id {
                if worldSelection["phase"] as? String == "failed" { throw UnityMarbleError.selectionRejected }
                if worldSelection["phase"] as? String == "activate",
                   worldSession?.context.state.worldID == id, spaceLibrary.savedSelectionID == id { return }
            }
            guard ContinuousClock.now < deadline else { throw UnityMarbleError.selectionTimedOut }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    /// `stage.world.enter`: the public-world menu. The only real entry is the
    /// existing `space.library.select` transaction — no second world owner and
    /// no locally remembered selection. An id the library does not list is
    /// rejected (`false` ⇒ `settings_command_rejected`), never silently kept.
    private func enterWorld(id: String) async throws {
        guard !closed, let entry = (spaceLibrary.snapshot["worlds"] as? [[String: Any]])?.first(where: { $0["id"] as? String == id }) else {
            throw UnityMarbleError.selectionRejected
        }
        if worldSession?.context.state.worldID == id, spaceLibrary.savedSelectionID == id { return }
        guard entry["manifestSHA256"] as? String != nil, spaceLibrary.package(for: id) != nil,
              spaceLibrary.settingsCommand(["op": "space.library.select", "id": id]),
              let revision = spaceLibrary.snapshot["selectionRevision"] as? UInt64 else { throw UnityMarbleError.selectionRejected }
        try await awaitWorldActivation(id: id, revision: revision)
    }
    /// `stage.scene.activate`: the generated-scene menu. Reuses the same
    /// preset activation the radio/agent path uses (`setSpatialEnvironment`).
    private func activateScene(presetID: String) async throws {
        guard !closed, let preset = SpatialScenePreset(rawValue: presetID) else { throw UnityMarbleError.selectionRejected }
        try await setSpatialEnvironment(scene: preset, weather: nil)
    }
    /// `stage.activity.run`: the measured activity path the menu uses. The id
    /// must be one this composition reports as runnable right now.
    private func runActivity(id: String) throws {
        guard !closed, let session = worldSession, session.canRunActivity(id: id) else { throw UnityMarbleError.selectionRejected }
        Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            do {
                try await session.context.startActivityMeasured(id: id)
                guard !self.closed, self.worldSession === session else { return }
                session.activity.invalidateProjection()
            } catch {
                guard !self.closed, self.worldSession === session else { return }
                self.notice = "活动未能开始：\(error.localizedDescription)"
            }
        }
    }
    /// `stage.activity.stop`: the authority's own stop, same call the menu uses.
    /// With nothing running there is nothing to stop — answers `false` so the
    /// UI receives `settings_command_rejected` instead of a no-op success.
    @discardableResult
    private func stopActivity() -> Bool {
        guard !closed, let session = worldSession, session.context.snapshot.activeActivity != nil else { return false }
        do { try session.context.stopActivity(reason: "用户从舞台设置停止活动") }
        catch { notice = "活动未能停止：\(error.localizedDescription)"; return false }
        session.activity.invalidateProjection()
        return true
    }
    /// The stage surface shape the settings window renders
    /// (`settings.stage` = `presentation`/`space`/`activities`/`player`), built
    /// from the values this host already owns. It is a projection only: every
    /// item comes from the live library/catalog/selection state.
    private func stageSnapshot(_ video: [String: Any], activity: [String: Any], activityItems: [[String: Any]],
                              presence: [String: Any]) -> [String: Any] {
        let worlds = (spaceLibrary.snapshot["worlds"] as? [[String: Any]]) ?? []
        let presets = (spaceLibrary.snapshot["marblePresets"] as? [[String: Any]]) ?? []
        let selected = worldSelection["worldID"] as? String ?? spaceLibrary.savedSelectionID
        let activeID = activity["activeActivity"] as? [String: Any]
        let phase = activeID?["phase"] as? String ?? (activity["activeID"] as? String).map { _ in "active" }
        let visible = worldSession != nil && selected != nil && worldSession?.context.state.worldID == selected
        let character = characterPosition?.snapshot() ?? [:]
        let xyz = character["position"] as? [Double] ?? []
        // The motion list the 角色 partition renders: exactly the keys
        // `apps/gpui-ui/src/stage_panels.rs` reads, sourced from the presence
        // bridge's own projection (the same shape `ProductHost.swift:165-172`
        // builds for the product host).
        let motions = ["avatarName": presence["avatarName"] ?? NSNull(),
                       "categories": presence["categories"] ?? [],
                       "items": presence["motions"] ?? [],
                       "activeID": presence["activeMotionID"] ?? NSNull(),
                       "isWorking": presence["working"] ?? false,
                       "notice": presence["motionNotice"] ?? NSNull(),
                       "message": presence["notice"] ?? NSNull(),
                       "hasError": presence["hasError"] ?? false] as [String: Any]
        return ["mode": visible ? "space" : "player",
                "stageRadioPluginEnabled": RadioPluginAvailability.isEnabled(defaults: defaults),
                "presentation": ["isWorldPresentationRequested": worldSession != nil || pendingWorldPackage != nil,
                                 "isWorldVisible": visible, "isDestinationButtonHidden": !visible,
                                 "isWorldInteractionHidden": !visible, "isPointCloudHidden": !visible,
                                 "isLoadingIndicatorHidden": visible, "isSpatialWorldHidden": !visible,
                                 "chatAvailable": true, "propsAvailable": true, "taskFeedbackVisible": true],
                "space": ["worlds": worlds, "presets": presets,
                          "selectedWorldID": selected as Any? ?? NSNull(),
                          "worldLabel": (worlds.first(where: { $0["id"] as? String == selected })?["name"] as? String) ?? "公开空间 · 无需生成",
                          "position": ["X": xyz.count == 3 ? xyz[0] : 0,
                                       "Y": xyz.count == 3 ? xyz[1] : 0,
                                       "Z": xyz.count == 3 ? xyz[2] : 0],
                          "isVisible": visible, "isRequested": worldSession != nil || pendingWorldPackage != nil,
                          "notice": worldSelection["message"] as? String ?? video["notice"] as Any? ?? NSNull(),
                          "generationMessage": (spaceLibrary.snapshot["marbleProgress"] as? String) as Any? ?? NSNull(),
                          "errorMessage": spaceLibrary.snapshot["marbleError"] as Any? ?? NSNull()] as [String: Any],
                "activities": ["items": activityItems, "activeID": activeID?["id"] as? String ?? activity["activeID"] as Any? ?? NSNull(),
                               "canRun": visible, "phase": phase as Any? ?? NSNull(),
                               "message": activity["notice"] as Any? ?? NSNull()] as [String: Any],
                "motions": motions,
                "player": ["lyrics": StageLyricsVisualMode.allCases.map { ["id": $0.agentValue, "name": $0.displayName] },
                           "lyricID": lyricsStore.visualMode.agentValue,
                           "clouds": StagePointCloudChoice.allCases.map { ["id": $0.rawValue, "name": $0.title] },
                           "cloudID": visualDirection.currentPointCloudChoice.rawValue,
                           "particleScale": visualDirection.particleSizeMultiplier,
                           "videoModes": StageVideoPlaybackMode.allCases.map { ["id": $0.rawValue, "name": $0.displayName] },
                           "videoMode": video["mode"] ?? NSNull(),
                           "videoActive": video["activeID"] is String,
                           "videoAssetID": video["activeID"] ?? NSNull(),
                           "videoBrightness": video["brightness"] ?? NSNull(),
                           "videoAssets": video["assets"] ?? [],
                           "videoBoundAssetID": video["boundAssetID"] ?? NSNull(),
                           "videoTrackID": video["currentTrackID"] ?? NSNull(),
                           "videoTrackTitle": video["currentTrackTitle"] ?? NSNull(),
                           "videoNotice": video["notice"] ?? NSNull(),
                           "videoCanRecoverStop": video["canRecoverStop"] ?? false]]
    }
    private func completeWorldSelection(_ value: [String: Any]) -> Bool {
        guard let revision = value["revision"] as? UInt64, revision == worldSelection["revision"] as? UInt64,
              let id = value["worldID"] as? String, id == worldSelection["worldID"] as? String,
              worldSelection["phase"] as? String == "prepare", let package = pendingWorldPackage,
              let success = value["success"] as? Bool else { return false }
        prepareWatchdogTask?.cancel(); prepareWatchdogTask = nil
        if !success {
            pendingWorldPackage = nil; worldSelection["phase"] = "failed"
            // The renderer's own named reason (timeout, rejected step, load
            // failure) travels with the receipt so a stuck prepare is never
            // reported as an anonymous rejection.
            let rendererCode = value["code"] as? String ?? "world_renderer_prepare_failed"
            worldSelection["code"] = rendererCode
            worldSelection["message"] = value["message"] as? String ?? "空间画面未能载入，原空间已保留。"
            NSLog("[UnityMediaHost] world selection: world=%@ phase=failed code=%@", id, rendererCode)
            _ = spaceLibrary.completeSelection(revision: revision, worldID: id, success: false)
            // 正常回执但 `success=false` 也是**同一条**收口：可重试的载入抖动走有界
            // 重试，用尽（或渲染侧已经给了确定性的条件名）才具名终局。以前这里
            // 一次都不重试，而真机 20:40 那次 `code=world_prepare_timeout` 正是走的
            // 这条路——同一份资产一小时前 17.1 s 就进过空间。
            if worldSession == nil {
                if Self.startupSpaceFailureIsRetryable(rendererCode) {
                    _ = retryStartupSpaceOrPublishFailure(rendererCode)
                } else {
                    // 渲染侧自己给了条件名（`world_prepare_rejected` 的那三类异常）：
                    // 重试只会把同一句拒绝再说四遍。这句更具体的说明留在
                    // `worldSelection["message"]` 里，终局仍然具名。
                    NSLog("[UnityMediaHost] space startup not retryable: %@ attempts=%ld/%ld",
                          rendererCode, startupSpaceAttempts, Self.startupSpaceAttemptLimit)
                }
            }
            return true
        }
        // Revalidate before retiring the old context. A render receipt cannot
        // authorize a package that changed during the asynchronous load.
        guard spaceLibrary.package(for: id) != nil else {
            pendingWorldPackage = nil; worldSelection["phase"] = "failed"
            worldSelection["code"] = "world_package_changed"
            worldSelection["message"] = "空间包在载入期间发生了变化，请重新选择空间。"
            NSLog("[UnityMediaHost] world selection: world=%@ phase=failed code=world_package_changed", id)
            _ = spaceLibrary.completeSelection(revision: revision, worldID: id, success: false)
            if worldSession == nil { _ = retryStartupSpaceOrPublishFailure("world_package_changed") }
            return true
        }
        let next: UnityWorldSessionComposition
        do {
            let nativeWorld = world
            next = try UnityWorldSessionComposition(applicationSupportBase: root, selectedWorldID: id, validatedPackage: package,
                nativePropFacts: { identity in try await nativeWorld.nativePropFacts(identity: identity) },
                nativePhysicsClient: worldPhysics)
            guard let record = worldSelection["record"] as? [String: Any], let state = record["state"] else { throw WorldAuthorityError.noAuthorityRecord }
            let rendered = try JSONDecoder().decode(WorldState.self, from: JSONSerialization.data(withJSONObject: state))
            guard next.context.state == rendered else {
                next.close()
                throw UnityWorldSessionComposition.CompositionError.authorityReadBehind
            }
        } catch {
            pendingWorldPackage = nil; worldSelection["phase"] = "failed"
            worldSelection["code"] = "world_authority_activation_failed"
            worldSelection["message"] = "空间状态在载入期间发生变化，请重新选择空间。"
            NSLog("[UnityMediaHost] world selection: world=%@ phase=failed code=world_authority_activation_failed type=%@", id, String(describing: type(of: error)))
            _ = spaceLibrary.completeSelection(revision: revision, worldID: id, success: false)
            // 默认路径（还没有任何 worldSession）遇到"载入期间状态前进"时按启动竞态
            // 处理：有界重试，而不是让启动停在播放器、等用户手动重新选一次空间。
            // 重试用尽同样具名终局（`publishStartupSpaceFailure`）。
            if worldSession == nil { _ = retryStartupSpaceOrPublishFailure("world_authority_activation_failed") }
            return true
        }
        residentAutonomy?.close(); devicePlacement?.close(); generationConfiguration?.close()
        wishOutputPreview?.close(); wishOutputPreview = nil
        worldSession?.close(); pendingWorldPackage = nil
        installWorldSession(next, selectedWorldID: id)
        worldSelection["phase"] = "activate"
        NSLog("[UnityMediaHost] world selection: world=%@ phase=activate revision=%llu", id, revision)
        _ = spaceLibrary.completeSelection(revision: revision, worldID: id, success: true)
        _ = world.command(["op": "world.snapshot", "worldID": id])
        return true
    }
    private func refreshGeneratedCatalog() {
        guard let session = worldSession, let catalog = generatedAssets else { return }
        do { try catalog.update(state: session.context.state, jobs: session.generationStore.jobs, revision: session.context.state.revision) }
        catch { notice = error.localizedDescription }
    }

    private func installWishOutputPreview(_ composition: UnityWorldSessionComposition, worldID: String) {
        wishOutputPreview?.close()
        let catalog = UnityWishOutputPreviewCatalog(root: root, worldID: worldID,
            residentScope: composition.residentScope, projectionSessionID: composition.wishProjectionSessionID,
            hostSessionID: composition.residentHostSessionID)
        wishOutputPreview = catalog
        catalog.onChange = { [weak self, weak composition, weak catalog] in
            guard let self, let composition, let catalog, !self.closed,
                  self.worldSession === composition, self.wishOutputPreview === catalog else { return }
            composition.updateWishOutputProjections(catalog.snapshot()["entries"] as? [[String: Any]] ?? [])
            if let failure = (catalog.snapshot()["errors"] as? [[String:String]])?.first {
                self.notice = "许愿输出预览暂不可用（" + (failure["code"] ?? "wish_output_preview_unavailable") + "）。"
            }
        }
        let refresh: @MainActor () -> Void = { [weak self, weak composition, weak catalog] in
            guard let self, let composition, let catalog, !self.closed,
                  self.worldSession === composition, self.wishOutputPreview === catalog else { return }
            catalog.update(wishes: composition.wishCoordinator.residentJobs(worldID: worldID,
                                                                            residentScope: composition.residentScope),
                           jobs: composition.generationStore.jobs)
        }
        let priorGenerationChange = composition.generationStore.onChange
        composition.generationStore.onChange = {
            priorGenerationChange?()
            refresh()
        }
        let priorWishChange = composition.wish.onStateChanged
        composition.wish.onStateChanged = {
            priorWishChange?()
            refresh()
        }
        refresh()
    }

    private func publishCharacterSelection(_ snapshot: StageAvatarRuntimeSnapshot) {
        guard !closed else { return }
        // The identity the renderer echoes is the authority's own revision for
        // this selection, not a per-publish counter: a load that outlives several
        // refreshes used to be answered with a revision that no longer matched
        // (2026-10-09 W2, `pendingRenderer` never cleared).
        characterSelectionRevision = presenceSettings.rendererSelectionRevision
        characterRuntimeRevision = snapshot.revision
        let active = presenceSettings.model.packages.first(where: \.isActive)
        let avatar: [String: Any]
        if let asset = snapshot.avatar {
            avatar = ["id": asset.id, "name": asset.name, "format": asset.format.rawValue,
                      "modelPath": asset.modelURL.path, "resourceRootPath": asset.resourceRootURL.path]
        } else {
            avatar = ["id": active?.manifest.id ?? PresencePackageStore.builtInOrbID,
                      "name": active?.manifest.name ?? "", "format": active?.manifest.engine.rawValue ?? "orb", "modelPath": ""]
        }
        let orb = presenceSettings.model.orbAppearance
        var selection: [String: Any] = ["revision": characterSelectionRevision, "avatar": avatar,
            "orbAppearance": ["red": orb.red, "green": orb.green, "blue": orb.blue, "flowIntensity": orb.flowIntensity]]
        if let motion = snapshot.motion {
            selection["motion"] = ["id": motion.id, "name": motion.name, "format": motion.format.rawValue,
                                   "path": motion.url?.path ?? "", "loop": motion.loop, "playbackRate": motion.playbackRate]
        }
        characterSelection = selection
    }

    private func entry(path: String, lyricPath: String? = nil) -> QueueEntry {
        let url = URL(fileURLWithPath: path)
        let adjacent = url.deletingPathExtension().appendingPathExtension("lrc")
        let lyric = lyricPath.map { URL(fileURLWithPath: $0) }
            ?? (FileManager.default.fileExists(atPath: adjacent.path) ? adjacent : nil)
        return QueueEntry(url: url, lyricURL: lyric)
    }

    private func didCommitMusicPlayback() {
        guard let state = musicPlayback.state, state.queue.indices.contains(state.index) else { return }
        let identity = state.sessionID, trackID = state.queue[state.index].id
        musicQueueRevision &+= 1
        player.setCompletionHandler { [weak self] in
            guard let self, !self.closed else { return }
            do {
                try self.musicPlayback.receipt(status: "completed", sessionID: identity, trackID: trackID)
                // An explicit replacement being prepared owns the next selection.
                guard self.musicPlayback.state?.pending == nil else { return }
                _ = self.command(["op": "music.next"])
            } catch { self.notice = error.localizedDescription }
        }
    }

    private func loadQueueEntry(_ ticket: RustMusicPlaybackClient.Ticket, autoplay: Bool) throws {
        let selected = try JSONDecoder().decode(QueueEntry.self, from: ticket.queue[ticket.index].payload)
        _ = try AVAudioFile(forReading: selected.url)
        guard try musicPlayback.isCurrent(ticket) else { throw CancellationError() }
        session &+= 1
        pausedPosition = nil
        lyricRevision &+= 1
        lines = []
        lyricsStore.clear()
        player.stop()
        try player.load(selected.url)
        nativeMusicRequestID = ticket.requestID
        try musicPlayback.commit(ticket, accepted: true)
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
        if autoplay {
            do {
                try player.play()
                try musicPlayback.receipt(status: "playing", sessionID: ticket.requestID, trackID: ticket.trackID)
            } catch {
                try? musicPlayback.receipt(status: "failed", sessionID: ticket.requestID, trackID: ticket.trackID)
                throw error
            }
        }
    }

    private func screenTools(isCurrent: @escaping @MainActor () -> Bool) -> [ResidentWorldToolSession.AdditionalTool] {
        screenVideo.tools(isCurrent: isCurrent).map { tool in
            ResidentWorldToolSession.AdditionalTool(name: tool.name, description: tool.description,
                inputSchema: tool.inputSchema, validate: { _ in isCurrent() }, handle: { callID, data in
                    let reply = await tool.handle(callID, data)
                    return .init(callID: callID, resultJSON: reply.payloadJSON, isError: reply.isError)
                })
        }
    }
    func command(_ value: [String: Any]) -> Bool {
        if value["op"] as? String == "ui.settings.command" {
            let answeredRequestID = value["requestID"] as? String
            guard !closed, gpuiSettingsTask == nil,
                  let requestID = answeredRequestID,
                  !requestID.isEmpty, requestID.utf8.count <= 128,
                  let command = value["command"] as? [String: Any],
                  let operation = command["op"] as? String,
                  (settingsSnapshot()["supportedCommands"] as? [String])?.contains(operation) == true else {
                // A rejection the window never hears about is a dead control.
                // Name it, log it, and (unless another command owns the slot)
                // answer the same requestID with the code.
                let busy = gpuiSettingsTask != nil
                let operation = (value["command"] as? [String: Any])?["op"] as? String ?? "ui.settings.command"
                let code = busy ? "settings_command_busy" : "settings_command_not_supported"
                settingsRefusal(op: operation, code: code)
                if !busy, let answeredRequestID, !answeredRequestID.isEmpty, answeredRequestID.utf8.count <= 128 {
                    gpuiSettingsResult = ["requestID": answeredRequestID, "status": "failed", "code": code]
                }
                return false
            }
            gpuiSettingsResult = ["requestID": requestID, "status": "pending"]
            gpuiSettingsRefusal = nil
            gpuiSettingsTask = Task { [weak self] in
                guard let self else { return }
                let completed = await self.settingsCommand(command)
                guard !self.closed, !Task.isCancelled else { return }
                // This is the existing owner's handler receipt. Some handlers
                // begin asynchronous persistence; only its later snapshot is
                // evidence of confirmed saved values. A refusal carries the
                // owner's own named reason when it has one.
                var receipt: [String: Any] = ["requestID": requestID, "status": completed ? "accepted" : "failed"]
                receipt["code"] = completed ? NSNull() : (self.gpuiSettingsRefusal ?? "settings_command_rejected")
                self.gpuiSettingsResult = receipt
                self.gpuiSettingsRefusal = nil
                self.gpuiSettingsTask = nil
            }
            return true
        }
        if value["op"] as? String == "world.physics.receipt" { return worldPhysics.accept(value) }
        // Same stage settings surface, reached when the native viewport (not the
        // settings window) submits the command. Accepted onto the same owners.
        if let op = value["op"] as? String, ["stage.world.enter", "stage.scene.activate"].contains(op) {
            Task { @MainActor [weak self] in _ = await self?.settingsCommand(value) }
            return true
        }
        if value["op"] as? String == "presence.position.rendered" { return characterPosition?.acknowledgeRendered(value) ?? false }
        if let op = value["op"] as? String, op == "presence.position" || op == "presence.position.reset" { return characterPosition?.command(value) ?? false }
        if let op = value["op"] as? String, UnityChatImageBridge.supportedCommands.contains(op) { return chatImages.command(value) }
        if value["op"] as? String == "spatial.presentation.receipt" { return spatialPresentation.command(value) }
        if value["op"] as? String == "ui.textInput" { return !closed && shortcutSettings.updateTextInput(value) }
        if value["op"] as? String == "tts.stop" { return !closed && productSettings.command(value) }
        if value["op"] as? String == "world.selection.prepared" { return completeWorldSelection(value) }
        if let operation = value["op"] as? String, UnityScreenVideoBridge.supportedCommands.contains(operation) {
            return screenVideo.command(value)
        }
        if ["world.device.place", "world.device.preview"].contains(value["op"] as? String ?? "") { return devicePlacement?.command(value) ?? false }
        if let operation = value["op"] as? String,
           operation == "activity.projected" || operation.hasPrefix("wish.") || operation == "inventory.retry" || operation == "inventory.delete" {
            return worldSession?.command(value) ?? false
        }
        do {
            switch value["op"] as? String {
            case "world.runtime.capabilities":
                guard !closed, let version = value["marbleSPZVersion"] as? NSNumber,
                      CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue.isFinite,
                      version.doubleValue == Double(version.intValue), [0, 2].contains(version.intValue) else { return false }
                marbleRuntimeReady = version.intValue == 2
                return true
            case "world.attachment.ready": return worldSession?.adoptAttachmentReadiness(value) ?? false
            case "presence.motion.completed":
                guard !closed,
                      let revision = value["revision"] as? UInt64,
                      revision == characterSelectionRevision,
                      revision == renderedCharacterSelectionRevision,
                      let characterID = value["characterID"] as? String,
                      characterID == renderedCharacterAssetID,
                      let motionID = value["motionID"] as? String else { return false }
                return presenceSettings.completeSelectedMotion(revision: characterRuntimeRevision, motionID: motionID)
            case "presence.runtime.result":
                // Identity comes from the bridge's *pending* selection (the
                // authority's revision), not from `characterSelectionRevision`
                // equalling a volatile per-publish counter: the counter advanced
                // on every snapshot refresh, so a real asset load's receipt was
                // rejected and `pendingRenderer` never cleared (2026-10-09 W2).
                guard let revision = value["revision"] as? UInt64, let success = value["success"] as? Bool,
                      presenceSettings.acceptsRendererReceipt(revision: revision) else { return false }
                let accepted = presenceSettings.command(["op": "presence.runtime.result", "revision": revision, "success": success])
                if accepted && success,
                   let avatar = characterSelection["avatar"] as? [String: Any],
                   let format = avatar["format"] as? String, let engine = PresenceEngine(rawValue: format) {
                    renderedCharacterEngine = engine
                    renderedCharacterAssetID = avatar["id"] as? String
                    renderedCharacterSelectionRevision = revision
                    _ = worldSession?.updateCharacterFormat(engine, assetID: renderedCharacterAssetID,
                        selectionRevision: revision)
                    try worldSession?.refreshApprovedMotions()
                }
                return accepted
            case "ui.intent.ack":
                guard let revision = value["revision"] as? UInt64, revision <= uiIntentRevision else { return false }
                uiIntents.removeAll { ($0["revision"] as? UInt64 ?? 0) <= revision }
                return true
            case "inbox.list", "inbox.read", "inbox.post": return inbox?.command(value) ?? false
            // `stage.load` has no production action: the stage/space state is
            // published by the snapshot projection every poll, and there is no
            // separate load step to run here. It stays in the settings
            // whitelist so the request reaches this handler, and it answers
            // `false` so the caller gets `settings_command_rejected` instead of
            // a fake accepted result (docs/plans/2026-10-08-ui-function-verification.md §4.2).
            case "stage.load": return false
            case "stage.player.lyrics":
                return settingsVisualCommand(value)
            case "stage.player.cloud", "stage.player.particles": return settingsVisualCommand(value)
            case "world.snapshot", "world.placement.evaluate", "world.placement.derive", "world.prop.preview", "world.prop.command", "world.prop.loaded":
                return world.command(value)
            case "music.library": return musicLibrary.refresh()
            case "music.program.history":
                Task { [weak self] in
                    guard let self else { return }
                    do { _ = musicLibrary.showProgramHistory(try await djProgram.refreshHistory()) }
                    catch { musicLibrary.reportProgramSelectionFailure(error) }
                }
                return true
            case "music.program.play":
                guard !closed, let id = value["programID"] as? String,
                      let slot = value["slotIndex"] as? NSNumber,
                      CFGetTypeID(slot) != CFBooleanGetTypeID(), slot.doubleValue.isFinite,
                      slot.doubleValue >= 0, slot.doubleValue <= Double(Int32.max),
                      slot.doubleValue.rounded() == slot.doubleValue else { return false }
                Task { [weak self] in
                    guard let self, !self.closed else { return }
                    do { try await self.djProgram.selectProgram(id: id, slotIndex: slot.intValue) }
                    catch { if !self.closed { self.musicLibrary.reportProgramSelectionFailure(error) } }
                }
                return true
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
                let entries = [entry(path: path, lyricPath: lyric)]
                let ticket = try musicPlayback.begin(queue: entries, ids: entries.map { $0.url.path }, index: 0, mode: "local")
                try loadQueueEntry(ticket, autoplay: value["autoplay"] as? Bool == true)
                musicLibrary.cancelPreparation(); libraryTrack = nil
            case "music.queue":
                guard let paths = value["paths"] as? [String], !paths.isEmpty,
                      paths.allSatisfy({ $0.hasPrefix("/") }) else { return false }
                let index = value["index"] as? Int ?? 0
                guard paths.indices.contains(index) else { return false }
                let entries = paths.map { entry(path: $0) }
                let ticket = try musicPlayback.begin(queue: entries, ids: entries.map { $0.url.path }, index: index, mode: "local")
                try loadQueueEntry(ticket, autoplay: value["autoplay"] as? Bool == true)
                musicLibrary.cancelPreparation(); libraryTrack = nil
            case "music.next":
                let ticket = try musicPlayback.navigate(delta: 1)
                if ticket.mode == "library" { return musicLibrary.select(ticket.index) }
                try loadQueueEntry(ticket, autoplay: true)
            case "music.select":
                guard let index = value["index"] as? Int else { return false }
                let ticket = try musicPlayback.navigate(slotIndex: index)
                if ticket.mode == "library" { return musicLibrary.select(ticket.index) }
                try loadQueueEntry(ticket, autoplay: true)
            case "music.previous":
                let ticket = try musicPlayback.navigate(delta: -1)
                if ticket.mode == "library" { return musicLibrary.select(ticket.index) }
                try loadQueueEntry(ticket, autoplay: true)
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
            case "music.seek": return false
            case "chat.send":
                guard takingChatImageRequestID == nil,
                      let id = value["requestID"] as? NSNumber, CFGetTypeID(id) != CFBooleanGetTypeID(),
                      id.doubleValue.isFinite, id.doubleValue >= 0,
                      id.doubleValue <= 9_007_199_254_740_991, id.doubleValue.rounded() == id.doubleValue,
                      chatImageSubmissions[id.uint64Value] == nil,
                      let text = value["text"] as? String else { return false }
                let imageState = chatImages.snapshot()
                let attachmentIDs: [String]
                let imageRevision: UInt64
                if value["attachmentIDs"] != nil || value["attachmentGeneration"] != nil {
                    guard let ids = value["attachmentIDs"] as? [String],
                          let generation = value["attachmentGeneration"] as? NSNumber,
                          CFGetTypeID(generation) != CFBooleanGetTypeID(), generation.doubleValue.isFinite,
                          generation.doubleValue >= 0, generation.doubleValue <= 9_007_199_254_740_991,
                          generation.doubleValue.rounded() == generation.doubleValue else { return false }
                    attachmentIDs = ids; imageRevision = generation.uint64Value
                } else {
                    attachmentIDs = []; imageRevision = imageState["generation"] as? UInt64 ?? 0
                }
                takingChatImageRequestID = id.uint64Value
                chatImageAdmissionTask = Task { @MainActor [self] in
                defer {takingChatImageRequestID = nil;chatImageAdmissionTask = nil}
                do {
                guard !closed, !Task.isCancelled else {return false}
                let submission = try await chatImages.takeSubmission(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                    attachmentIDs: attachmentIDs, generation: imageRevision)
                guard !closed, !Task.isCancelled else {
                    _ = await chatImages.restoreSubmission(submission)
                    chat.cancelUnstarted(requestID:id.uint64Value,submission:submission)
                    return false
                }
                let imageSession = worldSession
                residentAutonomy?.humanTurnWillBegin()
                if let autonomy = residentAutonomy, autonomy.usesRustScheduler {
                    guard scheduledHumanSubmission == nil, let imageSession else {
                        _ = await chatImages.restoreSubmission(submission); autonomy.humanTurnDidFinish(); return false
                    }
                    scheduledHumanSubmission = (id.uint64Value, submission, imageSession)
                    autonomy.loop.receiveUserMessage(submission.text, imageURLs: submission.attachments.map(\.url), submissionID: submission.id)
                } else {
                guard chat.send(requestID: id.uint64Value, submission: submission, authorizeImages: { [weak self, weak imageSession] runID, isCurrent in
                    guard let self, let imageSession, !self.closed,
                          self.worldSession === imageSession, isCurrent() else { throw CancellationError() }
                    try await imageSession.authorizeHumanImages(runID: runID, conversationID: self.humanImageConversationID,
                        attachments: submission.attachments, isCurrent: isCurrent)
                }) else {
                    _ = await chatImages.restoreSubmission(submission)
                    residentAutonomy?.humanTurnDidFinish(); return false
                }
                }
                chatImageSubmissions[id.uint64Value] = submission
                pushToTalk.cancel()
                productSettings.replySpeechEvent(requestID: String(id.uint64Value), kind: "accepted")
                return true
                } catch {notice = error.localizedDescription;return false}
                }
                return true
            case "chat.cancel":
                chatImageAdmissionTask?.cancel()
                guard let id = value["requestID"] as? NSNumber else { return false }
                if residentAutonomy?.usesRustScheduler == true,
                   scheduledHumanSubmission?.requestID == id.uint64Value { residentAutonomy?.loop.cancel() }
                let cancelled = chat.cancel(requestID: id.uint64Value)
                if cancelled { residentAutonomy?.humanTurnDidFinish() }
                productSettings.replySpeechEvent(requestID: String(id.uint64Value), kind: "cancelled")
                return cancelled
            case "resident.autonomy.pause": residentAutonomy?.pauseByUser(); return residentAutonomy != nil
            case "resident.autonomy.resume": residentAutonomy?.resumeByUser(); return residentAutonomy != nil
            case "resident.autonomy.editing":
                guard let editing = value["editing"] as? Bool, let residentAutonomy else { return false }
                residentAutonomy.setEditing(editing)
                if editing != worldEditing, let session = worldSession {
                    worldEditing = editing
                    worldEditingRevision &+= 1
                    let revision = worldEditingRevision
                    if editing { session.context.stopTicking() }
                    Task { @MainActor [weak self, weak session] in
                        guard let self, let session else { return }
                        do {
                            if !editing { _ = try await session.refreshAuthorityState() }
                            guard !self.closed, self.worldSession === session,
                                  self.worldEditingRevision == revision else { return }
                            if !editing { session.context.startTicking() }
                            // The editor must receive the checkpoint's current CAS
                            // revision before confirming a layout. Retry only this
                            // read if an in-flight geometry query owns the queue.
                            for _ in 0..<20 {
                                guard !self.closed, self.worldSession === session,
                                      self.worldEditingRevision == revision else { return }
                                if self.world.command(["op":"world.snapshot", "worldID":session.context.manifest.worldID]) { break }
                                try await Task.sleep(for:.milliseconds(100))
                            }
                        } catch { self.notice = error.localizedDescription }
                    }
                }
                return true
            case "voice.press", "voice.release", "voice.cancel": return pushToTalk.command(value)
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
            "notice": notice as Any? ?? NSNull(),
            "noticeSeverity": notice == nil ? "none" : "error"]
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
        if let events = conversation["events"] as? [[String: Any]] {
            for event in events {
                if let request = event["requestID"] as? NSNumber,
                   ["reply", "failure", "cancelled"].contains(event["kind"] as? String ?? ""),
                   let submission = chatImageSubmissions.removeValue(forKey: request.uint64Value) {
                    Task { @MainActor [self] in
                        if event["kind"] as? String == "reply" {await chatImages.finishSubmission(id:submission.id)}
                        else {_ = await chatImages.restoreSubmission(submission)}
                    }
                }
                if ["reply", "failure", "cancelled"].contains(event["kind"] as? String ?? "") {
                    residentAutonomy?.humanTurnDidFinish()
                }
                guard let request = event["requestID"] as? NSNumber else { continue }
                switch event["kind"] as? String {
                case "reply":
                    productSettings.replySpeechEvent(requestID: String(request.uint64Value), kind: "reply", source: event["speechSource"] as? [String: Any])
                case "failure", "cancelled":
                    productSettings.replySpeechEvent(requestID: String(request.uint64Value), kind: event["kind"] as! String)
                default: break
                }
            }
        }
        conversation["capabilities"] = ["streamingReplies": true, "deltaTextMode": "replace",
            "cancelActiveReply": true, "cancellationAcknowledgement": "local-turn-invalidated",
            "providerCancellationAcknowledgement": false]
        conversation["autonomousReplies"] = autonomousReplies
        let autonomySnapshot = residentAutonomy?.snapshot() ?? ["status": "world_unavailable"]
        conversation["autonomy"] = autonomySnapshot
        conversation["inboxAgent"] = inboxAgent?.snapshot() ?? ["status": "world_unavailable"]
        let worldServices = worldSession?.snapshot() ?? [:]
        let previewSnapshot = wishOutputPreview?.snapshot() ?? [:]
        if let session = worldSession {
            spatialPresentation.observeWorldWeather(worldID: session.context.state.worldID, value: session.context.state.weather)
        }
        return ["version": 1, "locale": productSettings.locale, "music": music, "musicLibrary": musicLibrary.snapshot(), "chat": conversation, "world": world.snapshot(), "inbox": worldServices["inbox"] ?? [:], "voice": pushToTalk.snapshot,
                "settings": settingsSnapshot(), "settingsCommandResult": gpuiSettingsResult,
                "worldSelection": worldSelection,
                "runtimeCapabilities": ["marbleSPZVersion": marbleRuntimeReady ? 2 : 0],
                "spatialPresentation": spatialPresentation.snapshot(),
                "chatAttachments": chatAttachmentSnapshot(),
                "characterPosition": characterPosition?.snapshot() ?? [:],
                "worldPhysicsProbes": worldPhysics.snapshot(),
                "visualSettingsCommand": visualCommandState,
                "selection": characterSelection, "uiIntents": uiIntents,
                "activity": worldServices["activity"] ?? NSNull(),
                "heldAvatarBindingNotice": worldServices["heldAvatarBindingNotice"] ?? NSNull(),
                "wish": worldServices["wish"] ?? NSNull(),
                "inventoryMutation": worldServices["inventoryMutation"] ?? [:],
                "builtinDevices": ["templates": deviceTemplates],
                "devicePlacement": devicePlacement?.snapshot() ?? [:],
                "generatedAssets": generatedAssets?.snapshot() ?? [:],
                "wishOutputPreview": previewSnapshot,
                "runtimeDiagnostics": runtimeDiagnostics(world: worldServices, autonomy: autonomySnapshot, preview: previewSnapshot),
                "screenVideo": screenVideo.snapshot(), "replySpeech": productSettings.replyPlaybackSnapshot]
    }

    private func chatAttachmentSnapshot() -> [String:Any] {
        var snapshot = chatImages.snapshot()
        if takingChatImageRequestID != nil {snapshot["canSubmit"] = false;snapshot["isPreparing"] = true}
        return snapshot
    }

    func close() {
        gpuiSettingsTask?.cancel(); gpuiSettingsTask = nil; gpuiSettingsRefusal = nil
        visualCommandTask?.cancel(); visualCommandTask=nil
        worldPhysics.close()
        closed = true
        chatImageDrop.close()
        savedProgramRestoreTask?.cancel(); savedProgramRestoreTask = nil
        spatialPresentation.close()
        characterPosition?.close()
        chatImageAdmissionTask?.cancel();chatImages.close();chatImageSubmissions.removeAll()
        openPanel?.cancel(nil)
        openPanel = nil
        player.stop()
        residentAutonomy?.close()
        inboxAgent?.close()
        wishOutputPreview?.close()
        chat.close()
        worldSession?.close()
        worldSelectionTask?.cancel(); pendingWorldPackage = nil; spaceLibrary.close()
        prepareWatchdogTask?.cancel(); prepareWatchdogTask = nil
        devicePlacement?.close()
        generationConfiguration?.close()
        screenVideo.close()
        world.close()
        musicLibrary.close()
        djProgram.shutdown()
        pushToTalk.close()
        shortcutSettings.stop()
        presenceSettings.stop()
        agentConnection.stop()
        productSettings.close()
    }

    private var residentSchedulerBindingKey: String?

    private func bindResidentSchedulerIfRequested() {
        guard let composition = worldSession, let autonomy = residentAutonomy else { return }
        let key = "\(ObjectIdentifier(composition))|\(composition.context.snapshot.worldID)|\(composition.residentScope)|\(chat.backend)"
        guard residentSchedulerBindingKey != key else { return }
        residentSchedulerBindingKey = key
        let endpoint = WorldAuthorityEndpoint(applicationSupportBase: root)
        let scheduler = RustResidentSchedulerClient(worldID: composition.context.snapshot.worldID,
            residentScope: composition.residentScope, endpointFile: endpoint.endpointFile,
            hostSessionID: composition.residentHostSessionID)
        autonomy.bindScheduler(scheduler, backend: chat.backend)
    }

    /// Record + log a named settings refusal. The player log gets the op, the
    /// code and the identifying field; the window's receipt gets the same code
    /// instead of `settings_command_rejected`. Names come from the authority's
    /// own vocabulary (`presence_renderer_pending`, `presence_motion_incompatible`)
    /// so a log line and a daemon refusal read the same.
    @discardableResult
    private func settingsRefusal(op: String, code: String, detail: String = "-") -> Bool {
        gpuiSettingsRefusal = code
        Self.settingsLog.error("settings command refused op=\(op, privacy: .public) code=\(code, privacy: .public) detail=\(detail, privacy: .public)")
        return false
    }

    private func settingsCommand(_ value: [String: Any]) async -> Bool {
        guard !closed, let op = value["op"] as? String else { return false }
        if let op = value["op"] as? String, UnityScreenVideoBridge.supportedCommands.contains(op) {
            return screenVideo.command(value)
        }
        defer { residentAutonomy?.refresh() }
        switch op {
        case "presence.position", "presence.position.reset": return characterPosition?.command(value) ?? false
        case _ where UnityMarbleWorldBridge.supportedCommands.contains(op): return spaceLibrary.settingsCommand(value)
        case "space.library.load", "space.library.select", "space.default": return spaceLibrary.settingsCommand(value)
        case "video.load", "video.choose", "video.select", "video.remove", "video.play", "video.pause", "video.stop", "video.mode", "video.brightness", "video.bind", "video.unbind", "video.bound.play", "video.bound.dismiss": return screenVideo.command(value)
        case "generation.load", "generation.save", "generation.check": return await generationConfiguration?.settingsCommand(value) ?? false
        case "settings.load":
            _ = musicLibrary.settingsCommand(["op": "music.load"])
            _ = presenceSettings.command(["op": "presence.load"])
            agentConnection.refresh()
            return productSettings.command(value)
        case "agent.status", "agent.login", "agent.logout", "agent.backend": return await agentConnection.command(value)
        case "agent.save":
            guard value.count > 1 else { return false }
            var remaining = value
            let autonomyEnabled = remaining.removeValue(forKey: "autonomyEnabled")
            guard autonomyEnabled == nil || autonomyEnabled is Bool,
                  autonomyEnabled == nil || residentAutonomy != nil else { return false }
            if let backend = remaining.removeValue(forKey: "backendID") {
                guard await agentConnection.command(["op": "agent.save", "backendID": backend]) else { return false }
            }
            guard remaining.count == 1 || productSettings.command(remaining) else { return false }
            if let enabled = autonomyEnabled as? Bool {
                if enabled { residentAutonomy?.resumeByUser() }
                else { residentAutonomy?.pauseByUser() }
            }
            return true
        case _ where UnityShortcutSettingsBridge.supportedCommands.contains(op): return shortcutSettings.command(value)
        // The settings window's world/scene/activity surface. `true` only means
        // the request was accepted onto the same owner the menu/agent path uses;
        // the world/scene phase and the activity id keep flowing through the
        // normal snapshot projection, so the UI never reads a local success.
        case "stage.world.enter":
            guard value.count == 2, let id = value["id"] as? String, !id.isEmpty, id.utf8.count <= 256 else { return false }
            do { try await enterWorld(id: id) } catch { notice = "未能进入该空间：\(error.localizedDescription)"; return false }
            return true
        case "stage.scene.activate":
            guard value.count == 2, let id = value["id"] as? String, !id.isEmpty, id.utf8.count <= 256 else { return false }
            do { try await activateScene(presetID: id) } catch { notice = "未能切换到该场景：\(error.localizedDescription)"; return false }
            return true
        case "stage.activity.run":
            guard value.count == 2, let id = value["id"] as? String, !id.isEmpty, id.utf8.count <= 256 else { return false }
            do { try runActivity(id: id) } catch { notice = "活动未能开始：\(error.localizedDescription)"; return false }
            return true
        case "stage.activity.stop": return stopActivity()
        case "presence.motion":
            guard let id = value["id"] as? String, !id.isEmpty, id.utf8.count <= 4096 else {
                return settingsRefusal(op: op, code: "presence_invalid_input")
            }
            // One predicate owns "can this row be selected right now": the same
            // one the bridge publishes per motion row. A control the snapshot
            // drew as selectable can therefore no longer be refused here, and a
            // refusal that does happen names itself instead of vanishing.
            if let refusal = presenceSettings.motionSelectionRefusal(id) {
                return settingsRefusal(op: op, code: refusal, detail: presenceSettings.selectionRefusalDetail(for: id))
            }
            residentAutonomy?.pauseByUser()
            do { try worldSession?.prepareManualMotionSelection() }
            catch {
                let detail: String
                if case .daemon(let code)? = error as? WorldAuthorityError { detail = "\(id):\(code)" }
                else { detail = "\(id):\(type(of: error))" }
                return settingsRefusal(op: op, code: "presence_world_not_ready", detail: detail)
            }
            // `prepareManualMotionSelection` stops the running activity, and that
            // stop synchronously begins this bridge's own `presence.motion.stop`
            // marker. Wait for it before asking for the selection again, so the
            // click is not refused by this host's own preparation (2026-10-09:
            // `side=bridge op=presence.motion.stop ageMs=0 kind=selection`).
            await presenceSettings.awaitSelectionPreparation()
            guard presenceSettings.command(value) else {
                let code = presenceSettings.motionSelectionRefusal(id) ?? "presence_selection_rejected"
                return settingsRefusal(op: op, code: code, detail: presenceSettings.selectionRefusalDetail(for: id))
            }
            return true
        case _ where UnityPresenceSettingsBridge.supportedCommands.contains(op): return presenceSettings.command(value)
        case "music.load", "music.connect", "music.disconnect", "music.sync": return musicLibrary.settingsCommand(value)
        // Same as the `command(_:)` arm: no production action exists behind
        // `stage.load`, so do not accept it. `false` becomes
        // `settingsCommandResult.status=failed` (code `settings_command_rejected`)
        // instead of a success the UI cannot observe.
        case "stage.load": return false
        case "stage.player.lyrics": return command(value)
        case "stage.player.cloud":
            return settingsVisualCommand(value)
        case "stage.player.particles":
            return settingsVisualCommand(value)
        default: return productSettings.command(value)
        }
    }
    private func settingsVisualCommand(_ value: [String: Any]) -> Bool {
        guard !closed, visualCommandTask == nil, let operation=value["op"] as? String else { return false }
        let requestID=value["requestID"] as? String ?? UUID().uuidString
        let perform: @MainActor () async throws -> Void
        switch operation {
        case "stage.player.lyrics":
            guard let raw=value["id"] as? String else {return false}
            perform = { [lyricsStore] in try await lyricsStore.setVisualMode(rawValue:raw) }
        case "stage.player.cloud":
            guard let raw=value["id"] as? String else {return false}
            perform = { [visualDirection] in try await visualDirection.selectPointCloud(rawValue:raw) }
        case "stage.player.particles":
            guard let number=value["value"] as? NSNumber else {return false}
            let raw=number.doubleValue
            perform = { [visualDirection] in try await visualDirection.setParticleSizeMultiplier(rawValue:raw) }
        default:return false
        }
        visualCommandState=["requestID":requestID,"operation":operation,"status":"pending"]
        visualCommandTask=Task { @MainActor [weak self] in
            guard let self else {return}
            defer {self.visualCommandTask=nil}
            do {
                try await perform();try Task.checkCancellation();guard !self.closed else {return}
                self.visualRevision &+= 1
                self.visualCommandState=["requestID":requestID,"operation":operation,"status":"completed"]
            } catch {
                self.visualCommandState=["requestID":requestID,"operation":operation,"status":"failed","code":"visual_settings_unconfirmed"]
            }
        }
        return true // ABI accepts a pending request; only the confirmed snapshot reports completion.
    }

    private func runtimeDiagnostics() -> [String: Any] {
        runtimeDiagnostics(world: worldSession?.snapshot() ?? [:],
            autonomy: residentAutonomy?.snapshot() ?? [:], preview: wishOutputPreview?.snapshot() ?? [:])
    }

    private func runtimeDiagnostics(world: [String: Any], autonomy: [String: Any], preview: [String: Any]) -> [String: Any] {
        UnityRuntimeDiagnostics.project(world: world,
            autonomy: autonomy,
            preview: preview,
            ambientEnabled: productSettings.authority.confirmed?.values.autonomyEnabled ?? false,
            editing: worldEditing)
    }

    private func settingsSnapshot() -> [String: Any] {
        let video = screenVideo.settingsSnapshot()
        var settings = productSettings.snapshot
        settings["music"] = musicLibrary.settingsSnapshot
        settings["presence"] = presenceSettings.snapshot
        settings["characterPosition"] = characterPosition?.snapshot() ?? [:]
        settings["shortcuts"] = shortcutSettings.snapshot
        settings["generation"] = generationConfiguration?.snapshot ?? [:]
        settings["video"] = video
        settings["spaceLibrary"] = spaceLibrary.snapshot
        var space = settings["space"] as? [String: Any] ?? [:]
        for (key, value) in spaceLibrary.defaultSpaceSnapshot { space[key] = value }
        settings["space"] = space
        var agent = settings["agent"] as? [String: Any] ?? [:]
        for (key, value) in agentConnection.snapshot {
            if (key == "notice" && value is NSNull) || (key == "hasError" && value as? Bool == false) { continue }
            agent[key] = value
        }
        settings["agent"] = agent
        settings["unity"] = ["availableSections": ["歌词", "视觉效果", "视频", "语音播放", "按住说话", "自主行动", "音乐账号与歌单同步", "角色管理", "动作管理", "Agent 连接", "快捷键", "生成服务", "我的空间"],
                             "availableAgentGroups": ["回复语音", "按住说话", "居民人格", "角色人格与偏好", "角色内核", "聊天模型", "自主行动"],
                             "planningSupported": true,
                             "autoSpeakSupported": true,
                             "unavailableMessage": "该页面尚未完成 Unity 运行时接线。"]
        // The stage surface the settings window's StagePanelsPane renders. The
        // keys are the ones `apps/gpui-ui/src/stage_panels.rs` reads
        // (`space.position.X/Y/Z`, `space.isVisible/isRequested/selectedWorldID`,
        // `activities.items/canRun/activeID`, `motions`), projected from the same
        // owners the rest of this host uses: `characterPosition` for the pose,
        // `spaceLibrary` + `worldSelection` for the space, the world session's
        // own runnable-activity list for the activity menu.
        let worldServices = worldSession?.snapshot() ?? [:]
        settings["stage"] = stageSnapshot(video, activity: worldServices["activity"] as? [String: Any] ?? [:],
                                          activityItems: worldSession?.availableActivityItems ?? [[String: Any]](),
                                          presence: presenceSettings.snapshot)
        return ["version": 1, "revision": visualRevision, "settings": settings,
                "runtimeDiagnostics": runtimeDiagnostics(),
                "supportedCommands": ["app.language", "settings.load", "speech.settings.load", "speech.settings.cancel", "stage.load",
                                      "stage.player.lyrics", "stage.player.cloud", "stage.player.particles", "agent.save",
                                      // The stage settings window's world/scene/activity controls. Each one is
                                      // dispatched in `settingsCommand` onto an owner that already exists
                                      // (the `space.library.select` transaction, `marbleWorlds.activatePreset`,
                                      // `startActivityMeasured` / `stopActivity`); no second world owner.
                                      "stage.world.enter", "stage.scene.activate", "stage.activity.run", "stage.activity.stop",
                                      "tts.provider", "tts.refresh", "tts.save", "tts.preview", "tts.stop", "asr.provider", "asr.save",
                                      "music.load", "music.connect", "music.disconnect", "music.sync", "generation.load", "generation.save", "generation.check", "space.library.load", "space.library.select", "space.default", "space.key.save", "space.key.clear"]
                                      + UnityShortcutSettingsBridge.supportedCommands
                                      + ["presence.position", "presence.position.reset"]
                                      + UnityPresenceSettingsBridge.supportedCommands
                                      + UnityAgentConnectionBridge.supportedCommands
                                      + UnityMarbleWorldBridge.supportedCommands
                                      + UnityScreenVideoBridge.supportedCommands]
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
        let mode = lyricsStore.resolvedVisualMode
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

@_cdecl("gmgn_unity_host_device_placement")
public func gmgnUnityHostDevicePlacement(_ handle: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int32) -> Int32 {
    guard Thread.isMainThread, let bytes, count > 0, count <= 64 * 1024 * 1024 else { return 0 }
    let copied = Data(bytes: bytes, count: Int(count))
    return withUnityHost(handle) { $0.enqueueDevicePlacement(copied) ? 1 : 0 } ?? 0
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
        Double(UnityWindowModeBridge.shared.targetWindow?.backingScaleFactor ?? 1)
    }
}

@_cdecl("gmgn_unity_window_width")
public func gmgnUnityWindowWidth() -> Double {
    guard Thread.isMainThread else { return 0 }
    return MainActor.assumeIsolated {
        Double(UnityWindowModeBridge.shared.targetWindow?.contentView?.bounds.width ?? 0)
    }
}

/// Normalized content coordinates, bottom-left origin, for the macOS fullscreen
/// mouse-release event whose Unity native position incorrectly becomes zero.
@_cdecl("gmgn_unity_cursor_content")
public func gmgnUnityCursorContent(_ axis: Int32) -> Double {
    guard Thread.isMainThread else { return .nan }
    return MainActor.assumeIsolated {
        guard let window = UnityWindowModeBridge.shared.targetWindow,
              let view = window.contentView, view.bounds.width > 0, view.bounds.height > 0 else { return .nan }
        let location = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = view.convert(location, from: nil)
        if axis == 0 { return Double((point.x - view.bounds.minX) / view.bounds.width) }
        let y = (point.y - view.bounds.minY) / view.bounds.height
        return Double(view.isFlipped ? 1 - y : y)
    }
}

@_cdecl("gmgn_unity_screen_pixels")
public func gmgnUnityScreenPixels(_ axis: Int32) -> Double {
    guard Thread.isMainThread else { return 0 }
    return MainActor.assumeIsolated {
        guard let screen = UnityWindowModeBridge.shared.targetWindow?.screen else { return 0 }
        return Double((axis == 0 ? screen.frame.width : screen.frame.height) * screen.backingScaleFactor)
    }
}

/// Read-only allowlist. Never forwards event summaries, intent/chat text,
/// provider errors, asset paths or credentials into the settings HTTP surface.
enum UnityRuntimeDiagnostics {
    static func project(world: [String: Any], autonomy: [String: Any], preview: [String: Any],
                        ambientEnabled: Bool, editing: Bool) -> [String: Any] {
        func select(_ source: [String: Any], _ keys: [String]) -> [String: Any] {
            Dictionary(keys.compactMap { key in source[key].map { (key, $0) } }, uniquingKeysWith: { first, _ in first })
        }
        let notifications = select(world["agentNotifications"] as? [String: Any] ?? [:],
            ["status", "consumer", "worldID", "residentScope", "pending", "queuedForAgent", "awaitingAcknowledgement", "pendingDurableWrites", "acknowledged"])
        var state = select(autonomy, ["status", "worldID", "isRunning", "isBackgroundRun", "isStopped",
            "isInvalidated", "backgroundEnabled", "intentPausedByUser", "humanTurnActive",
            "modelTurnsStarted", "backgroundModelTurnsStarted", "failedModelTurns", "cancelledModelTurns",
            "backgroundTurnsInLastHour", "backgroundTurnsPerHour"])
        state["ambientEnabled"] = ambientEnabled
        state["editing"] = editing
        var blockers: [String] = []
        if !ambientEnabled { blockers.append("ambient_disabled") }
        if editing { blockers.append("world_editing") }
        if autonomy["humanTurnActive"] as? Bool == true { blockers.append("human_turn_active") }
        if autonomy["isStopped"] as? Bool == true { blockers.append("user_stopped") }
        if autonomy["intentPausedByUser"] as? Bool == true { blockers.append("intent_paused_by_user") }
        if autonomy["isInvalidated"] as? Bool == true { blockers.append("loop_invalidated") }
        if autonomy["status"] as? String == "backend_or_world_unavailable" { blockers.append("backend_or_world_unavailable") }
        if autonomy.isEmpty { blockers.append("world_unavailable") }
        if let budget = autonomy["backgroundTurnsPerHour"] as? Int,
           let used = autonomy["backgroundTurnsInLastHour"] as? Int, used >= budget {
            blockers.append(budget == 0 ? "zero_budget" : "hourly_budget_exhausted")
        }
        state["observedBlockers"] = blockers
        state["ambientDisabledBlocksExistingTaskContinuation"] = false
        let entries = preview["entries"] as? [[String: Any]] ?? []
        let safeEntries = entries.map { select($0, ["objectID", "wishID", "sourceWishID", "taskID", "worldID", "stage"]) }
        let previewState: [String: Any] = ["worldID": preview["worldID"] ?? NSNull(),
            "generation": preview["generation"] ?? NSNull(), "entryCount": safeEntries.count,
            "phase": preview.isEmpty ? "unavailable" : (safeEntries.isEmpty ? "no_ready_entries" : "ready_entries"),
            "entries": safeEntries]
        return ["agentNotifications": notifications,
            "notificationRetryFailures": world["notificationRetryFailures"] as? Int ?? 0,
            "notificationError": world["notificationError"] as? String == "notification_not_confirmed"
                ? "notification_not_confirmed" : NSNull(),
            "autonomy": state, "wishOutputPreview": previewState,
            "renderedWishOutputIDs": world["renderedWishOutputIDs"] as? [String] ?? [],
            "currentActivityPhase": world["currentActivityPhase"] as? String ?? NSNull()]
    }
}
