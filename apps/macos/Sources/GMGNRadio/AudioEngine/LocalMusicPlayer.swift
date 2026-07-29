import Foundation

struct LocalTrack: Equatable, Sendable {
    var url: URL
    var title: String
    var duration: TimeInterval
}

enum LocalMusicPlaybackState: Equatable, Sendable {
    case idle
    case ready
    case playing
    case paused
    case finished
}

@MainActor
protocol LocalMusicPlaybackGraph: AnyObject {
    func load(
        _ url: URL,
        completion: @escaping @MainActor @Sendable () -> Void
    ) throws -> LocalTrack
    func play() throws
    func pause()
    func stop()
}

@MainActor
final class LocalMusicPlayer {
    private let graph: any LocalMusicPlaybackGraph
    private var playbackGeneration: UInt64 = 0

    private(set) var state: LocalMusicPlaybackState = .idle
    private(set) var track: LocalTrack?

    init(graph: any LocalMusicPlaybackGraph) {
        self.graph = graph
    }

    func load(_ url: URL) throws {
        playbackGeneration &+= 1
        let generation = playbackGeneration
        track = try graph.load(url) { [weak self] in
            guard
                let self,
                playbackGeneration == generation,
                state == .playing
            else {
                return
            }
            state = .finished
        }
        state = .ready
    }

    func play() throws {
        if state == .finished, let url = track?.url {
            try load(url)
        }
        guard track != nil else {
            return
        }
        try graph.play()
        state = .playing
    }

    func pause() {
        guard state == .playing else {
            return
        }
        graph.pause()
        state = .paused
    }

    func stop() {
        playbackGeneration &+= 1
        graph.stop()
        track = nil
        state = .idle
    }
}
