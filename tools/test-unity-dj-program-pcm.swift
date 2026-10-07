import Foundation
import AVFoundation
@testable import UnityMediaHost

// No network transport, provider account, planning agent or user archive is used.
struct PCMTransport: MusicProviderHTTPTransport {
    let bytes: Data
    func send(_ request: URLRequest) async throws -> MusicProviderHTTPResponse {
        precondition(request.url?.host == "fixture.invalid")
        return .init(data: bytes, statusCode: 200, mimeType: "audio/wav", responseURL: request.url)
    }
}
struct PCMProvider: AccountMusicProviderClient {
    func capabilities(session: MusicProviderSession) async throws -> MusicAccountCapabilities {
        .init(canSearchCatalog: true, canReadLibrary: true, canReadPlaylists: true, canReadRecentPlays: false, canPlay: true)
    }
    func search(_ request: MusicSearchRequest, session: MusicProviderSession) async throws -> [MusicProviderTrack] { [] }
    func fetchUserLibrary(session: MusicProviderSession) async throws -> MusicProviderLibrary { .init(savedTracks: [], playlists: [], recentlyPlayedTrackIDs: []) }
    func playbackAsset(for trackID: String, session: MusicProviderSession) async throws -> MusicPlaybackAsset {
        if trackID == "unavailable" { throw MusicProviderClientError.playbackUnavailable }
        return .init(url: URL(string: "https://fixture.invalid/\(trackID).wav")!, requestHeaders: [:])
    }
    func lyrics(for trackID: String, session: MusicProviderSession) async throws -> MusicLyrics { .init(original: "[00:00.00]fixture", translation: nil) }
}
actor DelayedRestorePCM: MusicProviderHTTPTransport {
    let bytes: Data
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    init(bytes: Data) { self.bytes = bytes }
    func send(_ request: URLRequest) async throws -> MusicProviderHTTPResponse {
        precondition(request.url?.host == "fixture.invalid")
        if request.url?.path.contains("restore-stale") == true {
            entered = true
            await withCheckedContinuation { waiting = $0 }
        }
        return .init(data: bytes, statusCode: 200, mimeType: "audio/wav", responseURL: request.url)
    }
    func release() { waiting?.resume(); waiting = nil }
}
func candidate(_ name: String) -> MusicCandidate {
    .init(id: "netease:\(name)", canonicalID: nil, providerID: .netease, source: .streaming,
          title: name, artist: "fixture", album: nil, duration: 8, isPlayable: true,
          matchScore: 1, userAffinity: 1, energy: 0.5, moodTags: [], genres: [], releaseYear: nil)
}
func program(_ id: String, _ names: [String]) -> ProgramPlan {
    .init(brief: .init(id: id, targetDuration: 1800, moodTags: [], energyArc: [], conversationMode: .ambient),
          slots: names.map { name in
              let track = candidate(name)
              return .init(track: track, role: .build, hostHint: .init(shouldTalkBefore: false, maxSentenceCount: 1,
                  selectionReason: "fixture", currentTrack: .init(id: track.id, title: track.title, artist: track.artist),
                  nextTrack: nil, facts: [], transitionIntent: nil))
          }, revision: 1, generatedAt: Date(), replanAfterTrackCount: 5, title: id)
}
enum Rejected: Error { case host }
@MainActor final class PCMObservations {
    var accepted: [String] = []
    var reject = true
    var released = 0
    var committed: [Int] = []
}
@main struct Regression {
    @MainActor static func main() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("gmgn-dj-pcm-\(UUID())")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        setenv("GMGN_UNITY_MUSIC_LIBRARY_ROOT", root.path, 1)
        let wave = root.appendingPathComponent("fixture.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 384000)!
        pcm.frameLength = pcm.frameCapacity
        pcm.floatChannelData![0].initialize(repeating: 0, count: Int(pcm.frameLength))
        try AVAudioFile(forWriting: wave, settings: format.settings).write(from: pcm)
        let sessions = InMemoryMusicProviderSessionStore()
        await sessions.save(.init(credential: .cookieHeader("isolated-fixture"), expiresAt: nil), for: .netease)
        let runtime = MusicRuntime(netease: NeteaseMusicSource(sessions: sessions, client: PCMProvider()),
            qqMusic: QQMusicSource(sessions: sessions, client: PCMProvider()), appleMusic: AppleMusicSource(),
            cache: StreamingMusicCache(rootURL: root.appendingPathComponent("cache"), transport: PCMTransport(bytes: try Data(contentsOf: wave))))
        let backend = MusicStorageRPCFixture()
        let library = UnityMusicLibraryBridge(root: root, runtime: runtime, storage: backend.client)
        defer { library.close() }
        let graph = AudioGraphController(visualStore: VisualAudioFeatureStore())
        let player = LocalMusicPlayer(graph: graph)
        defer { player.stop() }
        let observed = PCMObservations()
        library.onProgramPrepared = { url, _, track in
            // A begin ticket must not project a proposed queue before acceptance.
            precondition(library.queue.isEmpty || library.queue[library.index].id != track.id || track.title == "playing")
            if observed.reject { throw Rejected.host }
            try player.load(url)
            try player.play()
            let clock = try await player.confirmPlaybackProgress()
            precondition(clock.current > clock.start && player.isGraphPlaying)
            observed.accepted.append(track.id)
        }
        library.onToolPrepared = { url, _, track in
            do { try player.load(url); observed.accepted.append(track.id); return true } catch { return false }
        }
        library.onProgramSlotCommitted = { observed.committed.append($0) }
        library.onProgramPlaybackReleased = { observed.released += 1 }
        do { _ = try await library.activateProgram(program("unavailable", ["unavailable"])); preconditionFailure("Preflight should reject") } catch {}
        precondition(library.queue.isEmpty && observed.accepted.isEmpty)
        do { _ = try await library.activateProgram(program("rejected", ["playing", "later"])); preconditionFailure("Player should reject") } catch Rejected.host {}
        precondition(library.queue.isEmpty && observed.accepted.isEmpty)
        observed.reject = false
        let active = program("current", ["playing", "later"])
        let index = try await library.activateProgram(active)
        precondition(index == 0 && library.index == 0 && library.queue.map(\.title) == ["playing", "later"])
        let before = player.track?.url
        observed.reject = true
        do { _ = try await library.activateProgram(program("replacement", ["replacement"])); preconditionFailure("Replacement should reject") } catch Rejected.host {}
        precondition(library.queue.map(\.title) == ["playing", "later"] && player.track?.url == before && player.isGraphPlaying)
        do { _ = try await library.activateProgram(program("unavailable", ["unavailable"])); preconditionFailure("Replacement preflight should reject") } catch {}
        precondition(library.queue.map(\.title) == ["playing", "later"] && player.track?.url == before)
        observed.reject = false
        let revised = DJProgramEditor.revise(current: active, activeSlotIndex: 0, proposal: program("insert", ["inserted"]), mode: .insertNext)
        try await library.replaceUpcomingProgram(revised, at: 0)
        precondition(library.queue.map(\.title) == ["playing", "inserted", "later"] && player.track?.url == before && player.isGraphPlaying)
        _ = try await library.toolNavigate(1)
        precondition(library.index == 1 && observed.committed == [1] && library.queue[1].title == "inserted")
        precondition(!player.isGraphPlaying)
        try player.play()
        _ = try await player.confirmPlaybackProgress()
        let ordinary = MusicPlaylistSnapshot(id: "netease:playlist:ordinary", providerID: .netease, name: "ordinary", artworkURL: nil, tracks: [candidate("ordinary")])
        let store = SyncedMusicLibraryStore(storage: backend.client)
        let persisted = await store.mergeAndVerifyInBackground(playlists: [ordinary])
        precondition(persisted)
        _ = try await library.toolPrepare(playlistID: ordinary.id, trackID: candidate("ordinary").id)
        precondition(library.queue.map(\.title) == ["ordinary"] && observed.released == 1)
        do { try await library.replaceUpcomingProgram(revised, at: 0); preconditionFailure("Old program must lose ownership") } catch {}
        precondition(library.queue.map(\.title) == ["ordinary"])
        library.close()
        player.stop()
        let archiveRoot = root.appendingPathComponent("archive")
        var archived: UnityDJProgramBridge? = UnityDJProgramBridge(archiveRoot: archiveRoot, hooks: .init(
            plan: { _ in preconditionFailure("Restore must not plan") }, activate: { _ in preconditionFailure("Restore must not autoplay") },
            replaceUpcoming: { _, _ in }, notify: { _ in }), storage: backend.client)
        archived!.store.publish(revised)
        archived!.store.activateSlot(at: 1)
        try await archived!.store.flush()
        archived!.shutdown()
        archived = nil
        let restoredLibrary = UnityMusicLibraryBridge(root: root, runtime: runtime, storage: backend.client)
        defer { restoredLibrary.close() }
        restoredLibrary.onToolPrepared = { url, _, _ in
            do { try player.load(url); return true } catch { return false }
        }
        restoredLibrary.onProgramPrepared = { _, _, _ in preconditionFailure("Restore invoked autoplay") }
        let reopened = UnityDJProgramBridge(archiveRoot: archiveRoot, hooks: .init(
            plan: { _ in preconditionFailure("Restore must not plan") }, activate: { _ in preconditionFailure("Restore must not autoplay") },
            replaceUpcoming: { _, _ in }, notify: { _ in },
            restore: { try await restoredLibrary.restoreProgram($0, startingAt: $1) },
            selectHistorical: { try await restoredLibrary.activateProgram($0, startingAt: $1) }), storage: backend.client)
        let didRestore = try await reopened.restoreSavedPlayback()
        precondition(didRestore && reopened.store.activeSlot?.track.title == "inserted")
        precondition(restoredLibrary.index == 1 && restoredLibrary.queue.map(\.title) == ["playing", "inserted", "later"])
        precondition(player.state == .ready && !player.isGraphPlaying && reopened.activePlaybackPlan?.brief.id == "current")
        print("PASS: actual archive save/deinit/reopen restores exact slot through production PCM preflight and same player paused; no planning/autoplay")
        restoredLibrary.onProgramPrepared = { url, _, _ in
            if observed.reject { throw Rejected.host }
            try player.load(url); try player.play()
            let clock = try await player.confirmPlaybackProgress()
            precondition(clock.current > clock.start)
        }
        let historyRows = reopened.historySnapshot["programs"] as! [[String: Any]]
        precondition(historyRows.contains { $0["id"] as? String == "current" && $0["count"] as? Int == 3 })
        let restoredURL = player.track?.url
        observed.reject = true
        do { try await reopened.selectProgram(id: "current", slotIndex: 2); preconditionFailure("Failed history player replaced selection") } catch Rejected.host {}
        precondition(reopened.store.activeSlotIndex == 1 && restoredLibrary.index == 1 && player.track?.url == restoredURL)
        observed.reject = false
        try await reopened.selectProgram(id: "current", slotIndex: 2)
        precondition(reopened.store.activeSlotIndex == 2 && restoredLibrary.index == 2 && restoredLibrary.queue[2].title == "later" && player.isGraphPlaying)
        do { try await reopened.selectProgram(id: "current", slotIndex: 99); preconditionFailure("Invalid historical slot accepted") } catch UnityDJProgramBridge.Failure.noPreparedProgram {}
        print("PASS: archived history list and explicit exact-slot play use same production player; failure preserves previous selection; invalid slot rejected")
        let failedLibrary = UnityMusicLibraryBridge(root: root, runtime: runtime, storage: backend.client)
        defer { failedLibrary.close() }
        failedLibrary.onToolPrepared = { _, _, _ in preconditionFailure("Failed preflight reached player") }
        let priorURL = player.track?.url
        do { _ = try await failedLibrary.restoreProgram(program("failed", ["unavailable"]), startingAt: 0); preconditionFailure("Unavailable archive restored") } catch {}
        precondition(failedLibrary.queue.isEmpty && player.track?.url == priorURL && player.isGraphPlaying)
        let delayed = DelayedRestorePCM(bytes: try Data(contentsOf: wave))
        let staleRuntime = MusicRuntime(netease: NeteaseMusicSource(sessions: sessions, client: PCMProvider()),
            qqMusic: QQMusicSource(sessions: sessions, client: PCMProvider()), appleMusic: AppleMusicSource(),
            cache: StreamingMusicCache(rootURL: root.appendingPathComponent("stale-cache"), transport: delayed))
        let staleLibrary = UnityMusicLibraryBridge(root: root, runtime: staleRuntime, storage: backend.client)
        defer { staleLibrary.close() }
        staleLibrary.onToolPrepared = { url, _, _ in
            do { try player.load(url); return true } catch { return false }
        }
        let pendingRestore = Task { @MainActor in try await staleLibrary.restoreProgram(program("stale", ["restore-stale"]), startingAt: 0) }
        let restoreDeadline = Date().addingTimeInterval(5)
        while Date() < restoreDeadline {
            if await delayed.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let entered = await delayed.entered
        precondition(entered)
        _ = try await staleLibrary.toolPrepare(playlistID: ordinary.id, trackID: candidate("ordinary").id)
        let ordinaryURL = player.track?.url
        await delayed.release()
        do { _ = try await pendingRestore.value; preconditionFailure("Stale restore accepted") } catch is CancellationError {}
        precondition(staleLibrary.queue.map(\.title) == ["ordinary"] && player.track?.url == ordinaryURL)
        do { _ = try await staleLibrary.restoreProgram(revised, startingAt: 1); preconditionFailure("Restore stole ordinary queue") } catch is CancellationError {}
        precondition(staleLibrary.queue.map(\.title) == ["ordinary"] && player.track?.url == ordinaryURL)
        print("PASS: delayed restore lease loses to ordinary playlist intent; stale/failed restore never replaces current queue/player")
        print("PASS: real PCM/runtime/cache/preflight/player clock; rejected activation preserves queue; insertion preserves current; next pauses/prepares; ordinary playlist releases program owner; one player")
    }
}
