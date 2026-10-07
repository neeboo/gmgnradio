import Foundation

/// The formal radio protocol over the host's single real playback owner.
/// Awaited commands must finish only after the actual player accepts them.
@MainActor
final class UnityMusicRadioActions: DJAgentRadioActions {
    struct Track {
        let id: String
        let provider: String
        let title: String
        let artist: String
        let album: String?
        let duration: TimeInterval
    }
    struct Playback {
        let track: Track?
        let queue: [Track]
        let index: Int?
        let position: TimeInterval
        let isPlaying: Bool
    }
    enum Command {
        case play(trackID: String?, slotIndex: Int?)
        case next, previous, pause, resume
        case mood(StageVisualMood)
        case lyrics(StageLyricsVisualMode)
    }
    struct Hooks {
        let playback: @MainActor () -> Playback
        let command: @MainActor (Command) async throws -> Void
        let search: @MainActor (String, Int) async throws -> [DJAgentMusicTrack]
        let list: @MainActor (String?, Int, Int) async throws -> DJAgentMusicPlaylistsPage
        let read: @MainActor (String, Int, Int) async throws -> DJAgentMusicPlaylistPage
        let prepare: @MainActor (String, String) async throws -> DJAgentMusicPreparation
        var spatialEnvironment: (@MainActor (SpatialScenePreset?, SpatialWeather?) async throws -> Void)? = nil
        var spatialCamera: (@MainActor (SpatialCameraCommandDirection, Float) async throws -> Void)? = nil
    }
    private let hooks: Hooks
    private let program: UnityDJProgramBridge?
    init(hooks: Hooks, program: UnityDJProgramBridge? = nil) { self.hooks = hooks; self.program = program }

    func snapshot(takeoverEnabled: Bool) -> DJAgentRadioState {
        let state = hooks.playback()
        return .init(takeoverEnabled: takeoverEnabled,
            playbackState: state.track == nil ? "idle" : state.isPlaying ? "playing" : "paused",
            activeTrackID: state.track?.id, activeSlotIndex: state.index,
            program: state.queue.enumerated().map { .init(index: $0.offset, id: $0.element.id, title: $0.element.title, artist: $0.element.artist) },
            capabilities: DJAgentCapabilityManifest.capabilities.filter {
                ResidentMusicToolBridge.playbackNames.contains($0.name)
                    || (hooks.spatialEnvironment != nil && hooks.spatialCamera != nil && ResidentMusicToolBridge.spatialNames.contains($0.name))
                    || (program != nil && ["replan_program", "activate_prepared_program", "insert_track"].contains($0.name))
            })
    }
    func currentTrackSnapshot() -> DJAgentCurrentTrackSnapshot? {
        let state = hooks.playback()
        guard let track = state.track else { return nil }
        let duration = max(0, track.duration.isFinite ? track.duration : 0)
        let position = max(0, state.position.isFinite ? state.position : 0)
        func neighbor(_ offset: Int) -> DJAgentPlaybackTrack? {
            guard let index = state.index, state.queue.indices.contains(index + offset) else { return nil }
            let value = state.queue[index + offset]
            return .init(id: value.id, title: value.title, artist: value.artist)
        }
        return .init(sampledAt: ISO8601DateFormatter().string(from: Date()),
            playbackState: state.isPlaying ? "playing" : "paused", isPlaying: state.isPlaying,
            id: track.id, provider: track.provider, source: "unity-host-player", title: track.title,
            artist: track.artist, album: track.album, durationSeconds: duration, positionSeconds: position,
            remainingSeconds: max(0, duration - position), progress: duration > 0 ? min(1, position / duration) : 0,
            programID: program?.activePlaybackPlan?.brief.id, programTitle: program?.activePlaybackPlan?.title, slotIndex: state.index,
            previousTrack: neighbor(-1), nextTrack: neighbor(1))
    }
    func playProgramTrack(trackID: String?, slotIndex: Int?) async throws { try await hooks.command(.play(trackID: trackID, slotIndex: slotIndex)) }
    func playNextTrack() async throws { try await hooks.command(.next) }
    func playPreviousTrack() async throws { try await hooks.command(.previous) }
    func pauseMusic() async throws { try await hooks.command(.pause) }
    func resumeMusic() async throws { try await hooks.command(.resume) }
    func searchMusic(query: String, limit: Int) async throws -> [DJAgentMusicTrack] { try await hooks.search(query, limit) }
    func listMusicPlaylists(query: String?, offset: Int, limit: Int) async throws -> DJAgentMusicPlaylistsPage { try await hooks.list(query, offset, limit) }
    func readMusicPlaylist(playlistID: String, offset: Int, limit: Int) async throws -> DJAgentMusicPlaylistPage { try await hooks.read(playlistID, offset, limit) }
    func prepareMusicTrack(playlistID: String, trackID: String) async throws -> DJAgentMusicPreparation { try await hooks.prepare(playlistID, trackID) }
    func setVisualMood(_ mood: StageVisualMood) async throws { throw DJAgentMusicLibraryError.unsupported }
    func setLyricsMode(_ mode: StageLyricsVisualMode) async throws { try await hooks.command(.lyrics(mode)) }
    // These tools are not advertised by playbackNames. Unsupported operations
    // must never report success or silently mutate a different world owner.
    func replanProgram(immediateInstruction: String?) async throws {
        guard let program else { throw DJAgentMusicLibraryError.unsupported }
        try program.replan(immediateInstruction: immediateInstruction)
    }
    func activatePreparedProgram() async throws {
        guard let program else { throw DJAgentMusicLibraryError.unsupported }
        try await program.activate()
    }
    func insertTrack(immediateInstruction: String) async throws {
        guard let program else { throw DJAgentMusicLibraryError.unsupported }
        try program.insert(immediateInstruction: immediateInstruction)
    }
    func setSpatialEnvironment(scene: SpatialScenePreset?, weather: SpatialWeather?) async throws {
        guard let action = hooks.spatialEnvironment else { throw DJAgentMusicLibraryError.unsupported }
        try await action(scene, weather)
    }
    func moveSpatialCamera(direction: SpatialCameraCommandDirection, distance: Float) async throws {
        guard let action = hooks.spatialCamera else { throw DJAgentMusicLibraryError.unsupported }
        try await action(direction, distance)
    }
}
