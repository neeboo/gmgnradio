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
    /// 图**自己**报的"我现在在不在出声"。刻意没有默认实现：默认值就是替图撒谎。
    ///
    /// `AVAudioPlayerNode.play()` 只说明"我接受了一次 play 调用"，它不保证任何样本
    /// 到达扬声器。这里是"真的出声了"的第一半判据（第二半是前进中的播放位置）。
    var isPlaying: Bool { get }
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

/// 播放链上"没有出声"的**可见**原因。它们全部抛给调用方，不再只是一行日志。
enum LocalMusicPlaybackError: Error, LocalizedError, Equatable {
    /// 还没有加载任何音轨就要求播放。
    case trackNotLoaded
    /// 音频图拒绝播放，或者播放之后自报 `isPlaying == false`。
    case graphNotPlaying
    /// 图报告在播放，但播放位置在等待窗口里没有前进 —— 扬声器没收到声音。
    case playbackSilent(position: TimeInterval, waited: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .trackNotLoaded:
            "还没有加载任何音轨，点唱机无法出声。"
        case .graphNotPlaying:
            "音频引擎没有真正开始播放（isPlaying=false）。"
        case let .playbackSilent(position, waited):
            "音频引擎报告在播放，但播放位置停在 \(String(format: "%.2f", position)) 秒没有前进（等待 \(String(format: "%.1f", waited)) 秒）：扬声器没有收到声音。"
        }
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

    /// 音频图自己报的播放事实（不是我们记的 `state`）。
    var isGraphPlaying: Bool {
        graph.isPlaying
    }

    var playbackPosition: TimeInterval {
        graph.playbackPosition
    }

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
            throw LocalMusicPlaybackError.trackNotLoaded
        }
        do {
            try graph.play()
        } catch {
            logger.error(
                "play 失败：\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        // 「我们调过 play」不等于「有声音」。图自报没在播就是没播 —— 过去这里直接
        // 记成 `.playing`，于是调用方看到的状态是意图而不是事实，真机上表现为
        // "操作被接受、曲目也在、就是不出声"。
        guard graph.isPlaying else {
            logger.error("play 失败：音频图自报 isPlaying=false，音乐没有真正开始")
            throw LocalMusicPlaybackError.graphNotPlaying
        }
        state = .playing
        logger.info("play 完成：state=playing")
    }

    /// 「真的出声了」的唯一判据：图自报在播，**而且播放位置在前进**。
    ///
    /// 位置前进需要引擎真的在渲染；没有输出设备、设备被切走、或图只是接受了调用
    /// 而没有输出时，位置不会前进。返回观测到的 (起点, 终点) 供日志与断言引用。
    @discardableResult
    func confirmPlaybackProgress(
        timeout: TimeInterval = 2,
        minimumAdvance: TimeInterval = 0.05
    ) async throws -> (start: TimeInterval, current: TimeInterval) {
        let start = graph.playbackPosition
        let deadline = Date().addingTimeInterval(timeout)
        var observed = start
        while Date() < deadline {
            try Task.checkCancellation()
            guard graph.isPlaying else {
                logger.error("出声确认失败：音频图自报 isPlaying=false")
                throw LocalMusicPlaybackError.graphNotPlaying
            }
            observed = graph.playbackPosition
            if observed >= start + minimumAdvance {
                return (start, observed)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        logger.error(
            "出声确认失败：播放位置停在 \(observed, format: .fixed(precision: 3)) 秒（起点 \(start, format: .fixed(precision: 3))，等待 \(timeout, format: .fixed(precision: 1)) 秒）"
        )
        throw LocalMusicPlaybackError.playbackSilent(position: observed, waited: timeout)
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
