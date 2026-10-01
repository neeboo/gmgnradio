import Foundation
import Testing
@testable import GMGNRadio

@Test
@MainActor
func localMusicPlayerTracksLoadPlayPauseResumeAndCompletion() throws {
    let graph = LocalMusicPlaybackGraphSpy()
    var completionCount = 0
    let player = LocalMusicPlayer(
        graph: graph,
        onFinished: { completionCount += 1 }
    )
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
    #expect(completionCount == 1)

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

@Test
@MainActor
func localMusicPlayerCanReplaceItsCompletionHandlerForQueueIntegration() throws {
    let graph = LocalMusicPlaybackGraphSpy()
    var firstHandlerCount = 0
    var replacementHandlerCount = 0
    let player = LocalMusicPlayer(
        graph: graph,
        onFinished: { firstHandlerCount += 1 }
    )
    player.setCompletionHandler {
        replacementHandlerCount += 1
    }

    try player.load(URL(fileURLWithPath: "/tmp/first.wav"))
    try player.play()
    graph.finish()

    #expect(firstHandlerCount == 0)
    #expect(replacementHandlerCount == 1)
}

@MainActor
private final class LocalMusicPlaybackGraphSpy: LocalMusicPlaybackGraph {
    private var completions: [@MainActor @Sendable () -> Void] = []
    private(set) var loadCallCount = 0
    private(set) var playCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var stopCallCount = 0

    /// 这份 spy 模拟的是**真的会出声**的图：`play()` 之后它自报在播。
    /// `LocalMusicPlayer` 的"出声"判据要求图自己给出事实，spy 也必须给出。
    private var rendering = false
    private var startedAt: Date?
    var isPlaying: Bool {
        rendering
    }
    var playbackPosition: TimeInterval {
        guard rendering, let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    func load(
        _ url: URL,
        completion: @escaping @MainActor @Sendable () -> Void
    ) throws -> LocalTrack {
        loadCallCount += 1
        stopCallCount += 1
        rendering = false
        completions.append(completion)
        return LocalTrack(
            url: url,
            title: url.deletingPathExtension().lastPathComponent,
            duration: 180
        )
    }

    func play() throws {
        playCallCount += 1
        rendering = true
        startedAt = Date()
    }

    func pause() {
        pauseCallCount += 1
        rendering = false
        startedAt = nil
    }

    func stop() {
        stopCallCount += 1
        rendering = false
        startedAt = nil
    }

    func finish(at index: Int? = nil) {
        guard !completions.isEmpty else {
            return
        }
        rendering = false
        startedAt = nil
        completions[index ?? completions.count - 1]()
    }
}
