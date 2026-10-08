import Foundation
import Darwin
import Testing
@testable import GMGNRadio

@Test
func libraryIndexNormalizesMetadataWhenIngesting() async throws {
    let fixture = try await PrivateKnowledgeFixture()
    defer { fixture.stop() }
    let index = fixture.index

    await index.ingest(
        [
            knowledgeCandidate(
                id: "local-1",
                title: "  Blue   Hour ",
                artist: "  The   Lights "
            )
        ],
        origin: .saved,
        seenAt: Date(timeIntervalSince1970: 100)
    )

    let tracks = await index.snapshot()
    #expect(tracks.count == 1)
    #expect(tracks[0].title == "Blue Hour")
    #expect(tracks[0].artist == "The Lights")
    #expect(tracks[0].normalizedMetadataKey == "blue hour|the lights")
    #expect(tracks[0].isSaved)
}

@Test
func libraryIndexDeduplicatesTheSameRecordingAcrossProviders() async throws {
    let fixture = try await PrivateKnowledgeFixture()
    defer { fixture.stop() }
    let index = fixture.index
    let time = Date(timeIntervalSince1970: 100)

    await index.ingest(
        [
            knowledgeCandidate(
                id: "netease-1",
                canonicalID: "ISRC:US-ABC-24-00001",
                title: "Blue Hour",
                artist: "The Lights",
                providerID: .netease
            ),
            knowledgeCandidate(
                id: "qq-9",
                canonicalID: "isrc:us-abc-24-00001",
                title: "Blue Hour (Album Version)",
                artist: "The Lights",
                providerID: .qqMusic
            )
        ],
        origin: .saved,
        seenAt: time
    )

    let tracks = await index.snapshot()
    #expect(tracks.count == 1)
    #expect(tracks[0].identity == "canonical:isrc:us-abc-24-00001")
    #expect(Set(tracks[0].sources.map(\.trackID)) == ["netease-1", "qq-9"])
}

@Test
func libraryIndexMergesMetadataMatchWhenCanonicalIDArrivesLater() async throws {
    let fixture = try await PrivateKnowledgeFixture()
    defer { fixture.stop() }
    let index = fixture.index
    let time = Date(timeIntervalSince1970: 100)

    await index.ingest(
        [
            knowledgeCandidate(
                id: "local-1",
                title: "Café Blue",
                artist: "Beyoncé"
            )
        ],
        origin: .recent,
        seenAt: time
    )
    await index.ingest(
        [
            knowledgeCandidate(
                id: "stream-1",
                canonicalID: "ISRC:ONE",
                title: "Cafe Blue",
                artist: "Beyonce",
                providerID: .netease
            )
        ],
        origin: .saved,
        seenAt: time
    )

    let tracks = await index.snapshot()
    #expect(tracks.count == 1)
    #expect(tracks[0].identity == "canonical:isrc:one")
    #expect(tracks[0].sources.count == 2)
    #expect(tracks[0].isSaved)
}

@Test
func libraryIndexUsesABridgingSourceToMergeExistingIdentities() async throws {
    let fixture = try await PrivateKnowledgeFixture()
    defer { fixture.stop() }
    let index = fixture.index
    let time = Date(timeIntervalSince1970: 100)
    await index.ingest(
        [
            knowledgeCandidate(
                id: "canonical-source",
                canonicalID: "ISRC:BRIDGE",
                title: "Blue Hour Remaster",
                artist: "The Lights",
                providerID: .netease
            ),
            knowledgeCandidate(
                id: "metadata-source",
                title: "Blue Hour",
                artist: "The Lights"
            )
        ],
        origin: .recent,
        seenAt: time
    )

    await index.ingest(
        [
            knowledgeCandidate(
                id: "bridge-source",
                canonicalID: "ISRC:BRIDGE",
                title: "Blue Hour",
                artist: "The Lights",
                providerID: .qqMusic
            )
        ],
        origin: .saved,
        seenAt: time.addingTimeInterval(1)
    )

    let tracks = await index.snapshot()
    #expect(tracks.count == 1)
    #expect(Set(tracks[0].sources.map(\.trackID)) == [
        "canonical-source",
        "metadata-source",
        "bridge-source"
    ])
}

@Test
func listeningHistoryChangesAffinityInTheExpectedDirection() async throws {
    let fixture = try await PrivateKnowledgeFixture()
    defer { fixture.stop() }
    let index = fixture.index
    let time = Date(timeIntervalSince1970: 1_000)
    await index.ingest(
        [knowledgeCandidate(id: "track-1", title: "Known")],
        origin: .saved,
        seenAt: time
    )
    let initial = await index.snapshot()[0].affinityScore

    await index.record(.played(
        trackID: "track-1",
        completed: true,
        at: time.addingTimeInterval(100)
    ))
    await index.record(.liked(
        trackID: "track-1",
        isLiked: true,
        at: time.addingTimeInterval(200)
    ))
    let positive = await index.snapshot()[0].affinityScore

    await index.record(.skipped(
        trackID: "track-1",
        at: time.addingTimeInterval(300)
    ))
    let afterSkip = await index.snapshot()[0].affinityScore

    #expect(positive > initial)
    #expect(afterSkip < positive)
}

private func knowledgeCandidate(
    id: String,
    canonicalID: String? = nil,
    title: String,
    artist: String = "Artist",
    providerID: MusicProviderID = .local,
    isPlayable: Bool = true,
    matchScore: Double = 0.7,
    userAffinity: Double = 0.5,
    energy: Double = 0.5,
    moodTags: [String] = ["calm"]
) -> MusicCandidate {
    MusicCandidate(
        id: id,
        canonicalID: canonicalID,
        providerID: providerID,
        source: providerID == .local ? .localLibrary : .streaming,
        title: title,
        artist: artist,
        album: "Album",
        duration: 240,
        isPlayable: isPlayable,
        matchScore: matchScore,
        userAffinity: userAffinity,
        energy: energy,
        moodTags: moodTags,
        genres: ["electronic"],
        releaseYear: 2024
    )
}

/// Every former in-memory unit case now consumes a private real Rust authority.
/// No test can silently connect to the user's default application-support root.
private final class PrivateKnowledgeFixture: @unchecked Sendable {
    let index: InMemoryMusicLibraryIndex
    private let root: URL
    private let process: Process
    init() async throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { repository.deleteLastPathComponent() }
        let helper = repository.appendingPathComponent("target/debug/gmgn-taskd")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard let canonicalTemporary = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadInvalidFileName) }
        let temporaryPath = String(cString: canonicalTemporary)
        free(canonicalTemporary)
        root = URL(fileURLWithPath: temporaryPath + "/gmgn-knowledge-unit-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let endpoint = root.appendingPathComponent("endpoint.json")
        let transport = TaskdHTTPAuthorityClient(endpointFile: endpoint.path,
            helperPath: helper.path, allowsLaunching: false, timeout: 5)
        let client = RustMusicKnowledgeClient(scope: root.appendingPathComponent("knowledge").path) { method, data in
            let params = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: params))
        }
        index = InMemoryMusicLibraryIndex(client: client)
        process = Process()
        process.executableURL = helper
        process.arguments = ["--root", root.path, "--endpoint-file", endpoint.path, "--concurrency", "1"]
        let startupErrors = Pipe()
        process.standardOutput = FileHandle.nullDevice; process.standardError = startupErrors
        do {
            try process.run()
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: endpoint.path) { return }
                guard process.isRunning else {
                    let detail = String(decoding: startupErrors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    throw NSError(domain: "PrivateKnowledgeFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw CocoaError(.executableLoad)
        } catch { stop(); throw error }
    }
    func stop() {
        if process.isRunning {
            let pid = process.processIdentifier
            if getpgid(pid) == pid { _ = kill(-pid, SIGTERM) } else { process.terminate() }
            for _ in 0..<100 { if !process.isRunning { break }; usleep(50_000) }
            if process.isRunning { if getpgid(pid) == pid { _ = kill(-pid, SIGKILL) } else { _ = kill(pid, SIGKILL) } }
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: root)
    }
    deinit { stop() }
}
