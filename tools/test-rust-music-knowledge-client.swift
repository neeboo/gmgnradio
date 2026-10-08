import Foundation

// The harness extracts the real production HTTP class. This inert endpoint
// primitive must never be used: every client gets the private fixture endpoint.
struct WorldAuthorityEndpoint {
    static func taskServiceRoot() -> URL { fatalError("Fixture forbids default application-support access") }
}

@main struct KnowledgeAcceptance {
    static func candidate(_ id: String, canonical: String? = nil, title: String = "Café Blue",
                          artist: String = "Beyoncé", provider: MusicProviderID = .local) -> MusicCandidate {
        MusicCandidate(id: id, canonicalID: canonical, providerID: provider,
            source: provider == .local ? .localLibrary : .streaming,
            title: title, artist: artist, album: nil, duration: 120,
            isPlayable: true, matchScore: 0.8, userAffinity: 0.4, energy: 0.6,
            moodTags: [" Warm ", "warm"], genres: ["Jazz"], releaseYear: 2024)
    }
    static func main() async throws {
        precondition(CommandLine.arguments.count == 4)
        let endpoint = CommandLine.arguments[1], scope = CommandLine.arguments[2], phase = CommandLine.arguments[3]
        let transport = TaskdHTTPAuthorityClient(endpointFile: endpoint, helperPath: "/fixture-no-helper",
            allowsLaunching: false, timeout: 5)
        let client = RustMusicKnowledgeClient(scope: scope) { method, data in
            let params = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: params))
        }
        let index = InMemoryMusicLibraryIndex(client: client)
        if phase == "write" {
            await index.ingest([candidate("local-a")], origin: .recent, seenAt: Date(timeIntervalSince1970: 100))
            let before = await index.snapshot()
            precondition(before.count == 1 && before[0].normalizedMetadataKey == "cafe blue|beyonce")
            let event = MusicListeningEvent.played(trackID: "local-a", completed: false, at: Date(timeIntervalSince1970: 101))
            let started = try await client.record(event, requestID: "play-start-1")
            precondition(started.tracks[0].playCount == 1 && started.tracks[0].completedPlayCount == 0)
            let replay = try await client.record(event, requestID: "play-start-1")
            precondition(replay.revision == started.revision && replay.tracks == started.tracks)
            do {
                _ = try await client.record(.played(trackID: "local-a", completed: true, at: Date(timeIntervalSince1970: 101)), requestID: "play-start-1")
                fatalError("Changed request body must be refused")
            } catch WorldAuthorityError.daemon(let code) { precondition(code == "music_knowledge_request_conflict") }
            _ = try await client.record(.completed(trackID: "local-a", at: Date(timeIntervalSince1970: 102)), requestID: "finish-1")
            _ = try await client.record(.skipped(trackID: "local-a", at: Date(timeIntervalSince1970: 103)), requestID: "skip-1")
            _ = try await client.record(.liked(trackID: "local-a", isLiked: true, at: Date(timeIntervalSince1970: 104)), requestID: "like-1")
            await index.ingest([candidate("stream-b", canonical: " ISRC:ONE ", title: "Cafe Blue", artist: "Beyonce", provider: .netease)],
                origin: .saved, seenAt: Date(timeIntervalSince1970: 99))
            await index.ingest([candidate("qq-c", canonical: "isrc:one", title: "Blue Album Version", artist: "Beyonce", provider: .qqMusic)],
                origin: .discovery, seenAt: Date(timeIntervalSince1970: 105))
            let tracks = await index.snapshot()
            precondition(tracks.count == 1)
            let track = tracks[0]
            precondition(track.identity == "canonical:isrc:one" && track.sources.count == 3)
            precondition(track.origins == [.saved, .recent, .discovery])
            precondition(track.playCount == 1 && track.completedPlayCount == 1 && track.skipCount == 1 && track.isLiked)
            precondition(track.firstSeenAt == Date(timeIntervalSince1970: 99) && track.lastSeenAt == Date(timeIntervalSince1970: 105))
            precondition(track.lastPlayedAt == Date(timeIntervalSince1970: 102) && track.lastSkippedAt == Date(timeIntervalSince1970: 103))
            precondition(abs(track.affinityScore - 0.59) < 1e-9)
            print("PASS: actual client/index -> Rust merge, origins, dates, separate play/completed/skip, replay/conflict")
        } else if phase == "read" {
            let tracks = await index.snapshot()
            precondition(tracks.count == 1 && tracks[0].identity == "canonical:isrc:one")
            precondition(tracks[0].playCount == 1 && tracks[0].completedPlayCount == 1 && tracks[0].skipCount == 1)
            _ = try await client.record(.played(trackID: "local-a", completed: false, at: Date(timeIntervalSince1970: 101)), requestID: "play-start-1")
            let replayed = try await client.read()
            precondition(replayed.tracks[0].playCount == 1)
            print("PASS: daemon restart -> fresh actual Swift index reads persisted knowledge; replay remains one play")
        } else if phase == "legacy" {
            try await libraryIndexNormalizesMetadataWhenIngesting()
            try await libraryIndexDeduplicatesTheSameRecordingAcrossProviders()
            try await libraryIndexMergesMetadataMatchWhenCanonicalIDArrivesLater()
            try await libraryIndexUsesABridgingSourceToMergeExistingIdentities()
            try await listeningHistoryChangesAffinityInTheExpectedDirection()
            print("PASS: all five original knowledge assertions consume private real Rust authority")
        } else {
            let titles = ["Café Blue", "Cafe\u{301} Blue", "Beyoncé", "İstanbul", "Straße", "Æther", "Σίσυφος", "ＡＢＣ", "中文标题", "  Blue\u{a0}\tHour  "]
            let rows = titles.enumerated().map { candidate("golden-\($0.offset)", title: $0.element, artist: "Artist \($0.offset)") }
            let golden = try await client.ingest(rows, origin: .discovery, seenAt: Date(timeIntervalSince1970: 200), requestID: "unicode-golden")
            for (i, raw) in titles.enumerated() {
                let cleaned = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let key = cleaned.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
                    + "|artist \(i)"
                let track = golden.tracks.first { $0.sources.contains { $0.trackID == "golden-\(i)" } }!
                precondition(track.normalizedMetadataKey == key, "Foundation/Rust mismatch at golden \(i)")
                precondition(track.title == cleaned)
            }
            print("PASS: 10 real Foundation Unicode golden identities match Rust CF primitive")
        }
    }
}
