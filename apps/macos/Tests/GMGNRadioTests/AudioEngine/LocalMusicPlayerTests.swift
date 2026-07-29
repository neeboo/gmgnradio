import Foundation
import Testing
@testable import GMGNRadio

@Test
@MainActor
func localMusicPlayerTracksLoadPlayPauseResumeAndCompletion() throws {
    let graph = LocalMusicPlaybackGraphSpy()
    let player = LocalMusicPlayer(graph: graph)
    let trackURL = URL(fileURLWithPath: "/tmp/blue-hour.wav")

    try player.load(trackURL)
    #expect(player.state == .ready)
    #expect(player.track?.title == "blue-hour")

    try player.play()
    #expect(player.state == .playing)
    #expect(graph.playCallCount == 1)

    player.pause()
    #expect(player.state == .paused)
    #expect(graph.pauseCallCount == 1)

    try player.play()
    #expect(player.state == .playing)
    #expect(graph.playCallCount == 2)

    graph.finish()
    #expect(player.state == .finished)

    try player.play()
    #expect(player.state == .playing)
    #expect(graph.loadCallCount == 2)
    #expect(graph.playCallCount == 3)
}

@Test
@MainActor
func loadingAnotherTrackStopsThePreviousPlayback() throws {
    let graph = LocalMusicPlaybackGraphSpy()
    let player = LocalMusicPlayer(graph: graph)

    try player.load(URL(fileURLWithPath: "/tmp/first.wav"))
    try player.play()
    try player.load(URL(fileURLWithPath: "/tmp/second.wav"))

    #expect(graph.stopCallCount == 2)
    #expect(player.state == .ready)
    #expect(player.track?.title == "second")
}

@Test
@MainActor
func completionFromAnOldTrackCannotFinishTheCurrentTrack() throws {
    let graph = LocalMusicPlaybackGraphSpy()
    let player = LocalMusicPlayer(graph: graph)

    try player.load(URL(fileURLWithPath: "/tmp/first.wav"))
    try player.play()
    try player.load(URL(fileURLWithPath: "/tmp/second.wav"))
    try player.play()

    graph.finish(at: 0)

    #expect(player.state == .playing)
    #expect(player.track?.title == "second")
}

@MainActor
private final class LocalMusicPlaybackGraphSpy: LocalMusicPlaybackGraph {
    private var completions: [@MainActor @Sendable () -> Void] = []
    private(set) var loadCallCount = 0
    private(set) var playCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var stopCallCount = 0

    func load(
        _ url: URL,
        completion: @escaping @MainActor @Sendable () -> Void
    ) throws -> LocalTrack {
        loadCallCount += 1
        stopCallCount += 1
        completions.append(completion)
        return LocalTrack(
            url: url,
            title: url.deletingPathExtension().lastPathComponent,
            duration: 180
        )
    }

    func play() throws {
        playCallCount += 1
    }

    func pause() {
        pauseCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }

    func finish(at index: Int? = nil) {
        guard !completions.isEmpty else {
            return
        }
        completions[index ?? completions.count - 1]()
    }
}
