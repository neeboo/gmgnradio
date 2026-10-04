import Foundation
import Observation

@MainActor
@Observable
final class SyncedMusicLibraryStore {
    private struct Cache: Codable, Sendable {
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
    private var revision = 0

    /// Build, encode, write and verify the complete library away from the UI actor.
    /// Only the verified atomic-file publication and observable assignment run here.
    func mergeAndVerifyInBackground(playlists incoming: [MusicPlaylistSnapshot]) async -> Bool {
        let expectedRevision = revision
        let previous = playlists
        let destination = cacheURL
        let prepared = await Task.detached(priority: .utility) {
            let existing = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
            let providers = Set(incoming.map(\.providerID))
            var merged = previous.filter { !providers.contains($0.providerID) }
            merged += incoming.map { item in
                let old = existing[item.id]
                return MusicPlaylistSnapshot(id: item.id, providerID: item.providerID,
                    name: item.name, artworkURL: item.artworkURL ?? old?.artworkURL,
                    tracks: item.tracks.isEmpty ? old?.tracks ?? [] : item.tracks,
                    totalTrackCount: max(item.trackCount, old?.trackCount ?? 0))
            }
            merged.sort {
                $0.providerID != $1.providerID
                    ? $0.providerID.rawValue < $1.providerID.rawValue
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            guard let destination else { return (merged, Optional<URL>.none, true) }
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".music-library-\(UUID()).json")
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(Cache(playlists: merged)).write(to: temporary, options: .atomic)
                let verified = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: temporary))
                guard verified.playlists == merged else {
                    try? FileManager.default.removeItem(at: temporary)
                    return (merged, Optional<URL>.none, false)
                }
                return (merged, Optional(temporary), true)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                return (merged, Optional<URL>.none, false)
            }
        }.value
        guard prepared.2, revision == expectedRevision, !Task.isCancelled else {
            if let temporary = prepared.1 {
                Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: temporary) }
            }
            return false
        }
        if let temporary = prepared.1, let destination {
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try fileManager.moveItem(at: temporary, to: destination)
                }
            } catch {
                Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: temporary) }
                return false
            }
        }
        revision += 1
        playlists = prepared.0
        return true
    }

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
        revision += 1
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
        revision += 1
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
        revision += 1
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
