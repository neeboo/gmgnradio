import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let service = sources.appendingPathComponent("Agent/MusicLibraryAgentService.swift")
guard FileManager.default.fileExists(atPath: service.path) else {
    print("FAIL: shared music tools cannot browse or prepare the existing synced library")
    exit(1)
}
func read(_ path: String) throws -> String { try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8) }
func declaration(_ signature: String, in text: String) -> String {
    let start = text.range(of: signature)!.lowerBound
    let opening = text[start...].firstIndex(of: "{")!
    var depth = 0
    for index in text[opening...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]) }
    }
    fatalError("unterminated declaration")
}
let dj = try read("Agent/DJAgentToolDispatcher.swift")
let queue = try read("AudioEngine/ProgramPlaybackQueue.swift")
let planner = try read("DJCore/ProgramPlanner.swift")
let planTypes = String(planner[..<planner.range(of: "enum ProgramPlannerError:")!.lowerBound])
let dto = ["struct DJAgentMusicTrack:", "struct DJAgentMusicPlaylist:", "struct DJAgentMusicPlaylistsPage:",
           "struct DJAgentMusicPlaylistPage:", "struct DJAgentMusicPreparation:", "enum DJAgentMusicLibraryError:"]
    .map { declaration($0, in: dj) }.joined(separator: "\n")
let harness = #"""
import Foundation
import os
\#(try String(contentsOf: root.appendingPathComponent("tools/fixtures/MusicStorageRPCFixture.swift"), encoding: .utf8))
\#(planTypes)
\#(try read("DJCore/AgentShowProposal.swift"))
\#(dto)
\#(declaration("enum ProgramPlaybackQueueError:", in: queue))
@MainActor
\#(declaration("final class ProgramPlaybackQueue {", in: queue))
@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) {
    checks += 1; if !value { failures += 1; print("FAIL: \(message)") }
}
func track(_ id: String, provider: MusicProviderID = .netease) -> MusicCandidate {
    MusicCandidate(id: id, canonicalID: nil, providerID: provider, source: .streaming,
        title: "曲目 \(id)", artist: "测试艺人", album: nil, duration: 120, isPlayable: true,
        matchScore: 1, userAffinity: 1, energy: 0.4, moodTags: [], genres: [], releaseYear: nil,
        artworkURL: URL(string: "https://private.invalid/art?token=secret"))
}
func playlist(_ id: String = "netease:cozy", name: String = "Cozy 爵士", provider: MusicProviderID = .netease,
              tracks: [MusicCandidate] = [track("one")], total: Int = 3) -> MusicPlaylistSnapshot {
    MusicPlaylistSnapshot(id: id, providerID: provider, name: name,
        artworkURL: URL(string: "https://private.invalid/cover?token=secret"), tracks: tracks, totalTrackCount: total)
}
@MainActor final class Fixture: ProgramPlaybackPreparing {
    let backend = MusicStorageRPCFixture()
    lazy var store = SyncedMusicLibraryStore(storage: backend.client)
    lazy var programClient = RustMusicProgramClient(call: backend.call)
    lazy var programStore = DJProgramStore(client: programClient)
    var current = true
    var fetches: [(Int, Int)] = []
    var preparedIDs: [String] = []
    var commitCount = 0
    var committedIndex: Int?
    var committedQueue: ProgramPlaybackQueue?
    var held = false
    var holdFetch = false
    var waiting: CheckedContinuation<Void, Never>?
    var failFetch = false
    var failPrepare = false
    var providerTarget = false
    var badPage = false
    var noProgress = false
    lazy var service = MusicLibraryAgentService(store: store, programClient: programClient,
        fetchPage: { [unowned self] provider, id, offset, limit in
            self.fetches.append((offset, limit))
            if self.holdFetch { await withCheckedContinuation { self.waiting = $0 } }
            if self.failFetch { throw NSError(domain: "https://secret.invalid/token=secret", code: 1) }
            let all = [track("one"), track("two"), track("three")]
            return MusicPlaylistPage(playlistID: self.badPage ? "wrong" : id,
                tracks: self.noProgress ? [] : Array(all.dropFirst(offset).prefix(limit)), offset: offset, totalTrackCount: 3)
        }, makeQueue: { [unowned self] in ProgramPlaybackQueue(preflight: PlaybackPreflight(preparer: self), call: self.backend.call) },
        isCurrent: { [unowned self] in self.current },
        commit: { [unowned self] plan, queue, index in
            try await self.programStore.publish(plan)
            try await self.programStore.activateSlot(at: index)
            self.commitCount += 1; self.committedIndex = index; self.committedQueue = queue
        })
    init() { }
    func seed() async throws {
        store.remove(providerID: .netease); store.remove(providerID: .appleMusic)
        try await store.flush()
        store.merge(playlists: [playlist(), playlist("apple:only", name: "外部歌单", provider: .appleMusic,
            tracks: [track("apple-song", provider: .appleMusic)], total: 1)])
        try await store.flush()
    }
    func preparePlayback(for track: MusicCandidate) async throws -> PreparedPlaybackTarget {
        preparedIDs.append(track.id)
        if held { await withCheckedContinuation { waiting = $0 } }
        if failPrepare { throw NSError(domain: "https://secret.invalid/token=secret", code: 2) }
        return providerTarget ? .providerReference(providerID: .appleMusic, trackID: track.id) : .localFile(URL(fileURLWithPath: "/fixture/\(track.id).mp3"))
    }
    func waitUntilHeld() async {
        for _ in 0..<100_000 { if waiting != nil { return }; await Task.yield() }
        fatalError("operation did not reach injected boundary")
    }
}
@main struct Tests {
    @MainActor static func main() async throws {
        let backend = MusicStorageRPCFixture()
        if ProcessInfo.processInfo.environment["GMGN_MUSIC_LIBRARY_FIXTURE_PHASE"] == "reopen" {
            let store = SyncedMusicLibraryStore(storage: backend.client)
            try await store.reload()
            check(store.playlists.count == 2, "daemon restart preserves both providers")
            check(store.playlist(id: "netease:cozy")?.tracks.map(\.id) == ["one"], "daemon restart preserves confirmed cached prefix")
            check(store.playlist(id: "apple:only")?.tracks.map(\.id) == ["apple-song"], "daemon restart preserves other provider")
            print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) music library restart checks, \(failures) failures")
            exit(failures == 0 ? 0 : 1)
        }
        let backgroundStore = SyncedMusicLibraryStore(storage: backend.client)
        backgroundStore.remove(providerID: .netease); backgroundStore.remove(providerID: .appleMusic)
        try await backgroundStore.flush()
        let firstMerge = await backgroundStore.mergeAndVerifyInBackground(playlists: [playlist()])
        check(firstMerge && backgroundStore.playlists.count == 1, "background merge publishes verified data")
        let reopened = SyncedMusicLibraryStore(storage: backend.client)
        try await reopened.reload()
        check(reopened.playlists == backgroundStore.playlists, "background library is reopenable")
        let replacement = await backgroundStore.mergeAndVerifyInBackground(playlists: [playlist(name: "Updated", tracks: [], total: 3)])
        check(replacement && backgroundStore.playlists.first?.tracks.count == 1, "background replacement retains cached tracks")
        try await reopened.reload()
        check(reopened.playlists == backgroundStore.playlists, "database replacement publishes confirmed readback")
        let blockedBackend = MusicStorageRPCFixture(); blockedBackend.rejected = true
        let blockedStore = SyncedMusicLibraryStore(storage: blockedBackend.client)
        let blockedMerge = await blockedStore.mergeAndVerifyInBackground(playlists: [playlist()])
        check(!blockedMerge && blockedStore.playlists.isEmpty, "background write failure cannot publish unverified library")
        let f = Fixture(); try await f.seed()
        let listing = try f.service.list(query: "cozy", offset: 0, limit: 10)
        check(listing.playlists.count == 1 && listing.playlists.first?.id == "netease:cozy", "local title query returns existing playlist")
        check(f.fetches.isEmpty && f.preparedIDs.isEmpty && f.commitCount == 0, "listing cannot fetch, prepare or alter playback")
        let all = try f.service.list(query: nil, offset: 0, limit: 1)
        check(all.nextOffset == 1, "playlist listing supplies bounded continuation")
        let apple = try f.service.list(query: "外部", offset: 0, limit: 10)
        check(apple.playlists.first?.supportsPreparation == false, "external source is accurately marked unsupported")
        let page = try await f.service.read(playlistID: "netease:cozy", offset: 0, limit: 3)
        check(page.tracks.map(\.id) == ["one", "two", "three"] && page.nextOffset == nil, "read fills missing cached tracks through existing paging source")
        check(f.fetches.count == 1 && f.fetches.first?.0 == 1 && f.fetches.first?.1 == 2, "paging begins at cached boundary and fetches only requested remainder")
        _ = try await f.service.read(playlistID: "netease:cozy", offset: 1, limit: 1)
        check(f.fetches.count == 1 && f.commitCount == 0, "cached reread never fetches or starts playback")
        let wire = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
        check(!wire.contains("private.invalid") && !wire.contains("secret"), "model DTO exposes no private artwork or resource URL")
        let prepared = try await f.service.prepare(playlistID: "netease:cozy", trackID: "two")
        check(prepared.status == "prepared" && !prepared.isPlaying, "preparation never claims actual playback")
        check(f.preparedIDs == ["two"] && f.committedIndex == 1 && f.committedQueue?.current?.slot.track.id == "two",
              "real queue preflight selects exact requested cached track without fallback or prefetch")
        check(f.programStore.activeSlot?.track.id == "two", "native Store projects actual Rust selected slot")
        let authority = try await f.programClient.read()
        check(authority.plan == f.programStore.plan && authority.activeSlotIndex == 1, "same SQLite authority confirms publish and activation")
        let reloaded = DJProgramStore(client: RustMusicProgramClient(call: f.backend.call))
        try await reloaded.restoreLatest()
        check(reloaded.plan == f.programStore.plan && reloaded.activeSlot?.track.id == "two", "new native projection restores actual durable program and slot")
        let count = f.commitCount
        do { _ = try await f.service.prepare(playlistID: "netease:cozy", trackID: "invented"); check(false, "invented track must fail") }
        catch { check(error as? DJAgentMusicLibraryError == .trackNotFound && f.commitCount == count, "unknown ID cannot change playback") }
        for operation in ["read", "prepare"] {
            do {
                if operation == "read" { _ = try await f.service.read(playlistID: "apple:only", offset: 0, limit: 1) }
                else { _ = try await f.service.prepare(playlistID: "apple:only", trackID: "apple-song") }
                check(false, "external source must fail")
            } catch { check(error as? DJAgentMusicLibraryError == .sourceUnsupported, "\(operation) rejects external source before access") }
        }
        for mode in ["cancel", "stale", "removed", "replaced", "provider", "failure"] {
            let p = Fixture(); try await p.seed(); p.held = true
            let task = Task { @MainActor in try await p.service.prepare(playlistID: "netease:cozy", trackID: "one") }
            await p.waitUntilHeld()
            check(p.commitCount == 0, "\(mode): suspended preflight leaves official queue untouched")
            switch mode {
            case "cancel": task.cancel()
            case "stale": p.current = false
            case "removed": p.store.remove(providerID: .netease)
            case "replaced": p.store.merge(playlists: [playlist(tracks: [track("different")])])
            case "provider": p.providerTarget = true
            case "failure": p.failPrepare = true
            default: break
            }
            if mode == "removed" || mode == "replaced" { try await p.store.flush() }
            p.waiting?.resume(); p.waiting = nil
            do { _ = try await task.value; check(false, "\(mode) preparation cannot commit") }
            catch { check(p.commitCount == 0, "\(mode): rejected late preparation never commits") }
        }
        for mode in ["cancel", "stale", "bad-page", "failure", "no-progress"] {
            let p = Fixture(); try await p.seed(); p.holdFetch = true
            let task = Task { @MainActor in try await p.service.read(playlistID: "netease:cozy", offset: 1, limit: 2) }
            await p.waitUntilHeld()
            switch mode {
            case "cancel": task.cancel()
            case "stale": p.current = false
            case "bad-page": p.badPage = true
            case "failure": p.failFetch = true
            case "no-progress": p.noProgress = true
            default: break
            }
            p.waiting?.resume(); p.waiting = nil
            do { _ = try await task.value; check(false, "\(mode) page must not succeed") }
            catch {
                check(p.store.playlist(id: "netease:cozy")?.tracks.count == 1, "\(mode): invalid late page leaves cache unchanged")
                check(!error.localizedDescription.contains("secret"), "\(mode): provider errors are redacted")
            }
            check(p.store.loadingPlaylistIDs.isEmpty, "\(mode): paging busy marker is released")
        }
        for offset in [-1, Int.max] {
            do { _ = try f.service.list(query: nil, offset: offset, limit: 10); check(false, "invalid page bound cannot succeed") }
            catch { check(error as? DJAgentMusicLibraryError == .invalidArguments, "invalid list bounds are rejected without overflow") }
        }
        let farPage = Fixture(); try await farPage.seed()
        do { _ = try await farPage.service.read(playlistID: "netease:cozy", offset: 1000, limit: 10); check(false, "far page cannot fetch whole library") }
        catch { check(error as? DJAgentMusicLibraryError == .invalidArguments, "uncached far offset requires sequential pagination") }
        let busy = Fixture(); try await busy.seed(); busy.held = true
        let first = Task { @MainActor in try await busy.service.prepare(playlistID: "netease:cozy", trackID: "one") }
        await busy.waitUntilHeld()
        do { _ = try await busy.service.prepare(playlistID: "netease:cozy", trackID: "one"); check(false, "parallel preparation cannot commit over pending operation") }
        catch { check(error as? DJAgentMusicLibraryError == .busy && busy.preparedIDs == ["one"], "parallel preparation rejected before second preflight") }
        busy.waiting?.resume(); busy.waiting = nil
        _ = try await first.value
        check(busy.commitCount == 1, "only pending preparation commits once")
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) music library service checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-music-library-service-\(UUID())")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let program = temp.appendingPathComponent("Tests.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
func run(_ binary: String, _ args: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: binary); process.arguments = args
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
let sourceFiles = ["MusicSources/MusicSource.swift", "MusicSources/MusicStorageClient.swift", "DJCore/DJProgramStore.swift", "DJCore/RustMusicProgramClient.swift", "MusicKnowledge/TrackKnowledge.swift", "MusicKnowledge/CandidatePoolBuilder.swift", "MusicSources/SyncedMusicLibraryStore.swift",
    "Domain/PlaybackContext.swift", "AudioEngine/PlaybackPreflight.swift", "Agent/MusicLibraryAgentService.swift"]
let arguments = ["-j1", "-parse-as-library"] + sourceFiles.map { sources.appendingPathComponent($0).path } +
    [program.path, "-o", temp.appendingPathComponent("test").path]
let compiled = try run("/usr/bin/swiftc", arguments)
guard compiled == 0 else { exit(compiled) }
exit(try run(temp.appendingPathComponent("test").path, []))
