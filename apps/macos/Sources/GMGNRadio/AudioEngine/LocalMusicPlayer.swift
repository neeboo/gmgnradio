import Foundation
import os

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
    var playbackPosition: TimeInterval { get }

    func load(
        _ url: URL,
        completion: @escaping @MainActor @Sendable () -> Void
    ) throws -> LocalTrack
    func play() throws
    func pause()
    func stop()
}

extension LocalMusicPlaybackGraph {
    var playbackPosition: TimeInterval {
        0
    }
}

@MainActor
final class LocalMusicPlayer {
    private let logger = Logger(
        subsystem: "ai.gmgn.radio",
        category: "LocalMusicPlayer"
    )
    private let graph: any LocalMusicPlaybackGraph
    private var onFinished: @MainActor () -> Void
    private var playbackGeneration: UInt64 = 0

    private(set) var state: LocalMusicPlaybackState = .idle
    private(set) var track: LocalTrack?

    init(
        graph: any LocalMusicPlaybackGraph,
        onFinished: @escaping @MainActor () -> Void = {}
    ) {
        self.graph = graph
        self.onFinished = onFinished
    }

    func setCompletionHandler(
        _ onFinished: @escaping @MainActor () -> Void
    ) {
        self.onFinished = onFinished
    }

    func load(_ url: URL) throws {
        logger.info(
            "load 开始：url=\(url.path, privacy: .public)，state=\(String(describing: self.state), privacy: .public)"
        )
        playbackGeneration &+= 1
        let generation = playbackGeneration
        do {
            track = try graph.load(url) { [weak self] in
                guard
                    let self,
                    playbackGeneration == generation,
                    state == .playing
                else {
                    return
                }
                logger.info(
                    "播放完成回调：generation=\(generation)"
                )
                state = .finished
                onFinished()
            }
        } catch {
            logger.error(
                "load 失败：url=\(url.path, privacy: .public)，error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        state = .ready
        logger.info(
            "load 完成：title=\(self.track?.title ?? "nil", privacy: .public)，duration=\(self.track?.duration ?? 0, format: .fixed(precision: 2))，state=ready"
        )
    }

    func play() throws {
        logger.info(
            "play 开始：state=\(String(describing: self.state), privacy: .public)，hasTrack=\(self.track != nil)"
        )
        if state == .finished, let url = track?.url {
            try load(url)
        }
        guard track != nil else {
            logger.error("play 取消：尚未加载音轨")
            return
        }
        do {
            try graph.play()
        } catch {
            logger.error(
                "play 失败：\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        state = .playing
        logger.info("play 完成：state=playing")
    }

    func pause() {
        guard state == .playing else {
            logger.info(
                "pause 跳过：state=\(String(describing: self.state), privacy: .public)"
            )
            return
        }
        graph.pause()
        state = .paused
        logger.info("pause 完成：state=paused")
    }

    func stop() {
        logger.info(
            "stop：state=\(String(describing: self.state), privacy: .public)"
        )
        playbackGeneration &+= 1
        graph.stop()
        track = nil
        state = .idle
    }
}
