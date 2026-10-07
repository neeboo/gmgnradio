import Foundation
import Observation

@MainActor
@Observable
final class SyncedMusicLibraryStore {
    static let shared = SyncedMusicLibraryStore(storage: .shared)
    private(set) var playlists: [MusicPlaylistSnapshot] = []
    private(set) var isSyncing = false
    private(set) var loadingPlaylistIDs = Set<String>()
    private(set) var storageError: String?
    private(set) var isLoaded = false
    private let storage: MusicStorageClient?
    private var revision = 0
    private var mutation: Task<Void, Error>?

    /// Nil storage is an explicit in-memory fixture; live clients share Rust SQLite.
    init(storage: MusicStorageClient? = nil) {
        self.storage = storage
        isLoaded = self.storage == nil
    }

    func reload() async throws {
        do { try await flush() } catch { mutation = nil }
        guard let storage else { return }
        do {
            let value = try await storage.library()
            playlists = value.playlists; revision = value.revision; isLoaded = true; storageError = nil
        } catch { storageError = "歌单读取失败：\(error.localizedDescription)"; throw error }
    }
    func flush() async throws { try await mutation?.value }
    private func commit(_ edit: @escaping @MainActor ([MusicPlaylistSnapshot]) -> [MusicPlaylistSnapshot]) async throws {
        guard let storage else { playlists = edit(playlists); return }
        // Read the current revision before every edit, preventing stale client overwrite.
        let latest = try await storage.library()
        let result = try await storage.commit(edit(latest.playlists), revision: latest.revision)
        playlists = result.playlists; revision = result.revision; isLoaded = true; storageError = nil
    }
    private func enqueue(_ edit: @escaping @MainActor ([MusicPlaylistSnapshot]) -> [MusicPlaylistSnapshot]) {
        if storage == nil { playlists = edit(playlists); return }
        let previous = mutation
        mutation = Task {
            do { try await previous?.value } catch { }
            do { try await commit(edit) }
            catch { storageError = "歌单保存失败：\(error.localizedDescription)"; throw error }
        }
    }
    func mergeAndVerifyInBackground(playlists incoming: [MusicPlaylistSnapshot]) async -> Bool {
        enqueue { Self.merged($0, incoming: incoming) }
        do { try await flush(); return true } catch { return false }
    }
    func merge(playlists incoming: [MusicPlaylistSnapshot]) {
        enqueue { Self.merged($0, incoming: incoming) }
    }
    @discardableResult
    func mergeAndVerify(playlists incoming: [MusicPlaylistSnapshot]) -> Bool {
        merge(playlists: incoming)
        return storage == nil
    }
    private static func merged(_ previous: [MusicPlaylistSnapshot], incoming: [MusicPlaylistSnapshot]) -> [MusicPlaylistSnapshot] {
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
        return merged.sorted {
            $0.providerID != $1.providerID ? $0.providerID.rawValue < $1.providerID.rawValue
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    func setSyncing(_ syncing: Bool) { isSyncing = syncing }
    func remove(providerID: MusicProviderID) { enqueue { $0.filter { $0.providerID != providerID } } }
    func playlist(id: String) -> MusicPlaylistSnapshot? { playlists.first { $0.id == id } }
    func beginLoadingPage(playlistID: String) -> Bool { loadingPlaylistIDs.insert(playlistID).inserted }
    func finishLoadingPage(playlistID: String) { loadingPlaylistIDs.remove(playlistID) }
    func append(_ page: MusicPlaylistPage) {
        enqueue { existing in
            var result = existing
            guard let index = result.firstIndex(where: { $0.id == page.playlistID }) else { return result }
            let playlist = result[index]
            var seen = Set(playlist.tracks.map(\.id))
            let appended = page.tracks.filter { seen.insert($0.id).inserted }
            result[index] = MusicPlaylistSnapshot(id: playlist.id, providerID: playlist.providerID,
                name: playlist.name, artworkURL: playlist.artworkURL, tracks: playlist.tracks + appended,
                totalTrackCount: max(playlist.totalTrackCount, page.totalTrackCount))
            return result
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
