import Foundation

// Protocol/context test doubles; the adapter under test is production source.
typealias DJAgentRadioState = Int
typealias DJAgentCurrentTrackSnapshot = Int
typealias DJAgentMusicTrack = Int
typealias DJAgentMusicPlaylistsPage = Int
typealias DJAgentMusicPlaylistPage = Int
typealias DJAgentMusicPreparation = Int
typealias StageVisualMood = Int
typealias StageLyricsVisualMode = Int
typealias SpatialScenePreset = Int
typealias SpatialWeather = Int
typealias SpatialCameraCommandDirection = Int
@MainActor protocol DJAgentRadioActions: AnyObject {
    func snapshot(takeoverEnabled: Bool) -> Int
    func currentTrackSnapshot() -> Int?
    func playProgramTrack(trackID: String?, slotIndex: Int?) async throws
    func playNextTrack() async throws
    func playPreviousTrack() async throws
    func pauseMusic() async throws
    func resumeMusic() async throws
    func replanProgram(immediateInstruction: String?) async throws
    func activatePreparedProgram() async throws
    func insertTrack(immediateInstruction: String) async throws
    func setVisualMood(_ mood: Int) async throws
    func searchMusic(query: String, limit: Int) async throws -> [Int]
    func listMusicPlaylists(query: String?, offset: Int, limit: Int) async throws -> Int
    func readMusicPlaylist(playlistID: String, offset: Int, limit: Int) async throws -> Int
    func prepareMusicTrack(playlistID: String, trackID: String) async throws -> Int
    func setLyricsMode(_ mode: Int) async throws
    func setSpatialEnvironment(scene: Int?, weather: Int?) async throws
    func moveSpatialCamera(direction: Int, distance: Float) async throws
}
@MainActor final class UnityWorldSessionComposition {
    enum CompositionError: Error { case sessionClosed }
    var accepted = false, gates = 0
    func performJukebox(_ action: @escaping @MainActor () async throws -> Void) async throws {
        gates += 1
        guard accepted else { throw CompositionError.sessionClosed }
        try await action()
    }
}
@MainActor final class Player: DJAgentRadioActions {
    var plays = 0, pauses = 0
    func snapshot(takeoverEnabled: Bool) -> Int { 42 }
    func currentTrackSnapshot() -> Int? { 42 }
    func playProgramTrack(trackID: String?, slotIndex: Int?) async throws { plays += 1 }
    func playNextTrack() async throws { plays += 1 }
    func playPreviousTrack() async throws { plays += 1 }
    func pauseMusic() async throws { pauses += 1 }
    func resumeMusic() async throws { plays += 1 }
    func replanProgram(immediateInstruction: String?) async throws {}
    func activatePreparedProgram() async throws { plays += 1 }
    func insertTrack(immediateInstruction: String) async throws {}
    func setVisualMood(_ mood: Int) async throws {}
    func searchMusic(query: String, limit: Int) async throws -> [Int] { [42] }
    func listMusicPlaylists(query: String?, offset: Int, limit: Int) async throws -> Int { 42 }
    func readMusicPlaylist(playlistID: String, offset: Int, limit: Int) async throws -> Int { 42 }
    func prepareMusicTrack(playlistID: String, trackID: String) async throws -> Int { 42 }
    func setLyricsMode(_ mode: Int) async throws {}
    func setSpatialEnvironment(scene: Int?, weather: Int?) async throws {}
    func moveSpatialCamera(direction: Int, distance: Float) async throws {}
}
@main struct MusicActionsRegression {
    @MainActor static func main() async throws {
        let player = Player(), world = UnityWorldSessionComposition()
        let actions = UnityResidentMusicActions(base: player, world: world)
        do {
            try await actions.resumeMusic()
            fatalError("Unconfirmed arrival must never invoke player")
        } catch UnityWorldSessionComposition.CompositionError.sessionClosed {}
        precondition(player.plays == 0 && world.gates == 1)
        try await actions.pauseMusic(); precondition(player.pauses == 1 && world.gates == 1)
        let prepared = try await actions.prepareMusicTrack(playlistID: "p", trackID: "t")
        precondition(prepared == 42)
        precondition(world.gates == 1 && actions.currentTrackSnapshot() == 42)
        world.accepted = true
        try await actions.playProgramTrack(trackID: "t", slotIndex: nil)
        try await actions.playNextTrack(); try await actions.playPreviousTrack()
        try await actions.resumeMusic(); try await actions.activatePreparedProgram()
        precondition(player.plays == 5 && world.gates == 6)
        print("Unity resident music gate delegation regression passed")
    }
}
