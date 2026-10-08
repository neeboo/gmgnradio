import Foundation
import OSLog

enum MusicListeningEvent: Equatable, Sendable {
    case played(trackID: String, completed: Bool, at: Date)
    case completed(trackID: String, at: Date)
    case skipped(trackID: String, at: Date)
    case liked(trackID: String, isLiked: Bool, at: Date)

    var trackID: String {
        switch self {
        case let .played(trackID, _, _),
             let .completed(trackID, _), let .skipped(trackID, _),
             let .liked(trackID, _, _):
            trackID
        }
    }
}

protocol MusicLibraryIndexing: Sendable {
    func ingest(
        _ candidates: [MusicCandidate],
        origin: MusicLibraryOrigin,
        seenAt: Date
    ) async
    func record(_ event: MusicListeningEvent) async
    func snapshot() async -> [TrackKnowledge]
}

/// Historical name retained for callers; state and merging now belong to taskd.
actor InMemoryMusicLibraryIndex: MusicLibraryIndexing {
    private let authority: RustMusicKnowledgeClient
    private var confirmed = [TrackKnowledge]()
    private var revision: Int64 = -1
    private let logger = Logger(subsystem: "com.gmgnradio", category: "MusicKnowledge")
    init(client: RustMusicKnowledgeClient = .live) { self.authority = client }
    private func adopt(_ snapshot: RustMusicKnowledgeClient.Snapshot) {
        guard snapshot.revision >= revision else { return }
        revision = snapshot.revision; confirmed = snapshot.tracks
    }
    func ingest(_ candidates: [MusicCandidate], origin: MusicLibraryOrigin, seenAt: Date = Date()) async {
        do { adopt(try await authority.ingest(candidates, origin: origin, seenAt: seenAt)) }
        catch { logger.error("音乐知识采集回执失败：\(String(describing: error), privacy: .public)") }
    }
    func record(_ event: MusicListeningEvent) async {
        do { adopt(try await authority.record(event)) }
        catch { logger.error("音乐收听事实记录失败：\(String(describing: error), privacy: .public)") }
    }
    func snapshot() async -> [TrackKnowledge] {
        do { adopt(try await authority.read()) }
        catch { logger.error("音乐知识读回失败：\(String(describing: error), privacy: .public)") }
        return confirmed
    }
}
