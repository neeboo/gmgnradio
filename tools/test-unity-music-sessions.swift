import Foundation
#if GMGN_STORAGE_FULL_MODULE
@testable import UnityMediaHost
#endif

@main struct UnityMusicSessionsRegression {
    @MainActor static func main() async throws {
        let files = FileManager.default
        let temporary = files.temporaryDirectory.appendingPathComponent("unity-music-sessions-" + UUID().uuidString)
        defer { try? files.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("original-sessions")
        let root = temporary.appendingPathComponent("unity")
        try files.createDirectory(at: source, withIntermediateDirectories: true)
        let provider = MusicProviderID.netease
        let original = MusicProviderSession(credential: .cookieHeader("fixture-original"), expiresAt: nil)
        let originalFile = source.appendingPathComponent(provider.rawValue.utf8.map { String(format: "%02x", $0) }.joined() + ".json")
        let bytes = try JSONEncoder().encode(original)
        try bytes.write(to: originalFile)
        try files.setAttributes([.posixPermissions: 0o444], ofItemAtPath: originalFile.path)
        let before = try files.attributesOfItem(atPath: originalFile.path)[.posixPermissions] as! NSNumber
        let store = UnityMusicSessions(directory: source, root: root)
        let inherited = try await store.session(for: provider)
        precondition(inherited == original)
        try await store.removeSession(for: provider)
        let disconnected = try await store.session(for: provider)
        precondition(disconnected == nil)
        let restarted = UnityMusicSessions(directory: source, root: root)
        let stillDisconnected = try await restarted.session(for: provider)
        precondition(stillDisconnected == nil)
        let replacement = MusicProviderSession(credential: .cookieHeader("fixture-replacement"), expiresAt: nil)
        try await restarted.save(replacement, for: provider)
        let saved = try await store.session(for: provider)
        precondition(saved == replacement)
        let unchanged = try Data(contentsOf: originalFile)
        precondition(unchanged == bytes)
        let after = try files.attributesOfItem(atPath: originalFile.path)[.posixPermissions] as! NSNumber
        precondition(before == after)
        print("PASS inherited session read-only; disconnect survives restart; reconnect uses isolated session; source bytes/mode unchanged")
        let backend = MusicStorageRPCFixture()
        let library = SyncedMusicLibraryStore(storage: backend.client)
        let netease = MusicPlaylistSnapshot(id: "netease-list", providerID: .netease, name: "Fixture NetEase", artworkURL: nil, tracks: [])
        let qq = MusicPlaylistSnapshot(id: "qq-list", providerID: .qqMusic, name: "Fixture QQ", artworkURL: nil, tracks: [])
        let seedSaved = await library.mergeAndVerifyInBackground(playlists: [netease, qq])
        precondition(seedSaved)
        let updated = MusicPlaylistSnapshot(id: "netease-new", providerID: .netease, name: "Fixture New", artworkURL: nil, tracks: [])
        let updateSaved = await library.mergeAndVerifyInBackground(playlists: [updated])
        precondition(updateSaved)
        let readback = SyncedMusicLibraryStore(storage: backend.client)
        try await readback.reload()
        precondition(Set(readback.playlists.map(\.id)) == ["netease-new", "qq-list"])
        readback.remove(providerID: .netease)
        try await readback.flush()
        let disconnectedReadback = SyncedMusicLibraryStore(storage: backend.client)
        try await disconnectedReadback.reload()
        precondition(disconnectedReadback.playlists.map(\.id) == ["qq-list"])
        print("PASS verified isolated library publication/readback preserves other providers across sync and disconnect")
    }
}
