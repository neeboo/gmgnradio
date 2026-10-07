import Foundation

/// Reuses the host's actual player/provider/library actions. Only resident
/// playback is gated by walking to the user's placed jukebox; UI remains direct.
@MainActor final class UnityResidentMusicActions: DJAgentRadioActions {
    private let base: any DJAgentRadioActions
    private weak var world: UnityWorldSessionComposition?
    init(base: any DJAgentRadioActions, world: UnityWorldSessionComposition) {
        self.base = base; self.world = world
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) async throws {
        guard let world else { throw UnityWorldSessionComposition.CompositionError.sessionClosed }
        try await world.performJukebox(action)
    }
    func snapshot(takeoverEnabled: Bool) -> DJAgentRadioState { base.snapshot(takeoverEnabled: takeoverEnabled) }
    func currentTrackSnapshot() -> DJAgentCurrentTrackSnapshot? { base.currentTrackSnapshot() }
    func playProgramTrack(trackID: String?, slotIndex: Int?) async throws {
        try await perform { [base] in try await base.playProgramTrack(trackID: trackID, slotIndex: slotIndex) }
    }
    func playNextTrack() async throws { try await perform { [base] in try await base.playNextTrack() } }
    func playPreviousTrack() async throws { try await perform { [base] in try await base.playPreviousTrack() } }
    func resumeMusic() async throws { try await perform { [base] in try await base.resumeMusic() } }
    func pauseMusic() async throws { try await base.pauseMusic() }
    func replanProgram(immediateInstruction: String?) async throws { try await base.replanProgram(immediateInstruction: immediateInstruction) }
    func activatePreparedProgram() async throws { try await perform { [base] in try await base.activatePreparedProgram() } }
    func insertTrack(immediateInstruction: String) async throws { try await base.insertTrack(immediateInstruction: immediateInstruction) }
    func setVisualMood(_ mood: StageVisualMood) async throws { try await base.setVisualMood(mood) }
    func searchMusic(query: String, limit: Int) async throws -> [DJAgentMusicTrack] { try await base.searchMusic(query: query, limit: limit) }
    func listMusicPlaylists(query: String?, offset: Int, limit: Int) async throws -> DJAgentMusicPlaylistsPage {
        try await base.listMusicPlaylists(query: query, offset: offset, limit: limit)
    }
    func readMusicPlaylist(playlistID: String, offset: Int, limit: Int) async throws -> DJAgentMusicPlaylistPage {
        try await base.readMusicPlaylist(playlistID: playlistID, offset: offset, limit: limit)
    }
    func prepareMusicTrack(playlistID: String, trackID: String) async throws -> DJAgentMusicPreparation {
        try await base.prepareMusicTrack(playlistID: playlistID, trackID: trackID)
    }
    func setLyricsMode(_ mode: StageLyricsVisualMode) async throws { try await base.setLyricsMode(mode) }
    func setSpatialEnvironment(scene: SpatialScenePreset?, weather: SpatialWeather?) async throws {
        try await base.setSpatialEnvironment(scene: scene, weather: weather)
    }
    func moveSpatialCamera(direction: SpatialCameraCommandDirection, distance: Float) async throws {
        try await base.moveSpatialCamera(direction: direction, distance: distance)
    }
}
