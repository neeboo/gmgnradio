import Foundation
import Observation

@MainActor
@Observable
final class SyncedMusicLibraryStore {
    private struct Cache: Codable {
        var version = 1
        var playlists: [MusicPlaylistSnapshot]
    }

    static let shared = SyncedMusicLibraryStore(
        cacheURL: FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("ai.gmgn.radio", isDirectory: true)
            .appendingPathComponent("music-library.json")
    )

    private(set) var playlists: [MusicPlaylistSnapshot] = []
    private(set) var isSyncing = false
    private(set) var loadingPlaylistIDs = Set<String>()
    private let cacheURL: URL?
    private let fileManager: FileManager

    init(
        cacheURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.cacheURL = cacheURL
        self.fileManager = fileManager
        guard
            let cacheURL,
            let data = try? Data(contentsOf: cacheURL),
            let cache = try? JSONDecoder().decode(Cache.self, from: data)
        else {
            return
        }
        playlists = cache.playlists
    }

    func setSyncing(_ syncing: Bool) {
        isSyncing = syncing
    }

    func merge(playlists incoming: [MusicPlaylistSnapshot]) {
        _ = mergeAndVerify(playlists: incoming)
    }

    @discardableResult
    func mergeAndVerify(
        playlists incoming: [MusicPlaylistSnapshot]
    ) -> Bool {
        let previousPlaylists = playlists
        let existingByID = Dictionary(
            uniqueKeysWithValues: playlists.map { ($0.id, $0) }
        )
        let providers = Set(incoming.map(\.providerID))
        playlists.removeAll { providers.contains($0.providerID) }
        playlists.append(contentsOf: incoming.map { playlist in
            let existing = existingByID[playlist.id]
            let tracks = playlist.tracks.isEmpty
                ? (existing?.tracks ?? [])
                : playlist.tracks
            return MusicPlaylistSnapshot(
                id: playlist.id,
                providerID: playlist.providerID,
                name: playlist.name,
                artworkURL: playlist.artworkURL ?? existing?.artworkURL,
                tracks: tracks,
                totalTrackCount: max(
                    playlist.trackCount,
                    existing?.trackCount ?? 0
                )
            )
        })
        playlists.sort {
            if $0.providerID != $1.providerID {
                return $0.providerID.rawValue < $1.providerID.rawValue
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        guard persist() else {
            playlists = previousPlaylists
            _ = persist()
            return false
        }
        return true
    }

    func remove(providerID: MusicProviderID) {
        playlists.removeAll { $0.providerID == providerID }
        _ = persist()
    }

    func playlist(id: String) -> MusicPlaylistSnapshot? {
        playlists.first { $0.id == id }
    }

    func beginLoadingPage(playlistID: String) -> Bool {
        guard loadingPlaylistIDs.insert(playlistID).inserted else {
            return false
        }
        return true
    }

    func finishLoadingPage(playlistID: String) {
        loadingPlaylistIDs.remove(playlistID)
    }

    func append(_ page: MusicPlaylistPage) {
        guard let index = playlists.firstIndex(where: {
            $0.id == page.playlistID
        }) else {
            return
        }
        let playlist = playlists[index]
        var seen = Set(playlist.tracks.map(\.id))
        let appended = page.tracks.filter {
            seen.insert($0.id).inserted
        }
        playlists[index] = MusicPlaylistSnapshot(
            id: playlist.id,
            providerID: playlist.providerID,
            name: playlist.name,
            artworkURL: playlist.artworkURL,
            tracks: playlist.tracks + appended,
            totalTrackCount: max(
                playlist.totalTrackCount,
                page.totalTrackCount
            )
        )
        _ = persist()
    }

    private func persist() -> Bool {
        guard let cacheURL else {
            return true
        }
        do {
            try fileManager.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(
                Cache(playlists: playlists)
            ).write(to: cacheURL, options: .atomic)
            let readback = try JSONDecoder().decode(
                Cache.self,
                from: Data(contentsOf: cacheURL)
            )
            return readback.playlists == playlists
        } catch {
            return false
        }
    }
}

enum SyncedPlaylistProgramBuilder {
    static func makePlan(
        from playlist: MusicPlaylistSnapshot,
        generatedAt: Date = Date()
    ) -> ProgramPlan {
        let tracks = playlist.tracks
        let slots = tracks.indices.map { index in
            let track = tracks[index]
            let next = tracks.indices.contains(index + 1)
                ? tracks[index + 1]
                : nil
            return ProgramSlot(
                track: track,
                role: role(at: index, count: tracks.count),
                hostHint: ProgramHostHint(
                    shouldTalkBefore: index > 0 && index % 3 == 0,
                    maxSentenceCount: 1,
                    selectionReason: "来自你的歌单《\(playlist.name)》",
                    currentTrack: reference(for: track),
                    nextTrack: next.map(reference(for:)),
                    facts: facts(for: track),
                    transitionIntent: next.map {
                        transitionIntent(from: track, to: $0)
                    }
                )
            )
        }
        return ProgramPlan(
            brief: ProgramBrief(
                id: playlist.id,
                targetDuration: tracks.reduce(0) { $0 + $1.duration },
                moodTags: [],
                energyArc: tracks.map(\.energy),
                conversationMode: .ambient,
                immediateUserInstruction: "播放我的歌单《\(playlist.name)》"
            ),
            slots: slots,
            revision: 1,
            generatedAt: generatedAt,
            replanAfterTrackCount: max(1, min(3, slots.count)),
            title: playlist.name,
            direction: "已同步歌单"
        )
    }

    private static func role(at index: Int, count: Int) -> ProgramSlotRole {
        if index == 0 { return .opener }
        if index == count - 1 { return .closer }
        let progress = Double(index) / Double(max(count - 1, 1))
        if progress < 0.4 { return .build }
        if progress < 0.72 { return .peak }
        return .cooldown
    }

    private static func reference(for track: MusicCandidate) -> TrackReference {
        TrackReference(id: track.id, title: track.title, artist: track.artist)
    }

    private static func facts(for track: MusicCandidate) -> [String] {
        var result = ["艺人：\(track.artist)"]
        if let album = track.album, !album.isEmpty {
            result.append("专辑：\(album)")
        }
        return result
    }

    private static func transitionIntent(
        from current: MusicCandidate,
        to next: MusicCandidate
    ) -> String {
        let delta = next.energy - current.energy
        if delta > 0.12 { return "逐步提亮" }
        if delta < -0.12 { return "自然放缓" }
        return "延续当前质感"
    }
}
