import Foundation
import CryptoKit

actor CacheFixtureTransport: MusicProviderHTTPTransport {
    var count = 0
    let bytes = Data([0x49, 0x44, 0x33, 0x04, 0, 0, 0, 0, 0, 0, 0xff, 0xfb, 0x90, 0x64])
    func send(_ request: URLRequest) async throws -> MusicProviderHTTPResponse {
        precondition(request.value(forHTTPHeaderField: "Cookie") == "private-cookie-never-persist")
        count += 1
        return .init(data: bytes, statusCode: 200, mimeType: "audio/mpeg")
    }
}
@main struct MusicCacheAcceptance {
    static func main() async throws {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        let rawAuthority = TaskdHTTPAuthorityClient(endpointFile: args[2], helperPath: "/no-launch", allowsLaunching: false, timeout: 60)
        let client = RustMusicCacheClient(call: { method, input in
            let result = try rawAuthority.call(method: method,
                params: JSONSerialization.jsonObject(with: input) as! [String: Any])
            if method == "music_cache_claim", let path = result["stagePath"] as? String {
                let stage = URL(fileURLWithPath: path).standardizedFileURL
                let directory = root.appendingPathComponent("MusicCache", isDirectory: true).standardizedFileURL
                print("GUARD parent=\(stage.deletingLastPathComponent().absoluteString) root=\(directory.absoluteString) rootresolved=\(directory.resolvingSymlinksInPath().absoluteString) stageResolved=\(stage.resolvingSymlinksInPath().absoluteString)")
                fflush(stdout)
            }
            return try JSONSerialization.data(withJSONObject: result)
        }, taskRoot: root, hostSessionID: "private-cache-session")
        let transport = CacheFixtureTransport()
        let cache = StreamingMusicCache(authority: client, transport: transport)
        let asset = MusicPlaybackAsset(url: URL(string: "https://not-contacted.invalid/song.mp3?signed=private-secret")!,
            requestHeaders: ["Cookie": "private-cookie-never-persist"])
        let diagnostic = try await client.prepare(trackID: "netease:42", fileExtension: "mp3", requestID: "initial-private-plan")
        let plannedPath = URL(fileURLWithPath: diagnostic.stagePath!)
        print("PATH root=\(client.directory.path) planned=\(plannedPath.path) resolved=\(plannedPath.resolvingSymlinksInPath().path)")
        fflush(stdout)
        let first = try await cache.store(asset, trackID: "netease:42")
        let expected = transport.bytes
        let firstData = try Data(contentsOf: first)
        precondition(firstData == expected)
        let second = try await cache.store(asset, trackID: "netease:42")
        precondition(first == second)
        let firstCount = await transport.count
        precondition(firstCount == 1)
        let changedFormat = MusicPlaybackAsset(url: URL(string: "https://not-contacted.invalid/song.m4a?signed=changed")!,
            requestHeaders: asset.requestHeaders)
        let sameTrackFormat = try await cache.store(changedFormat, trackID: "netease:42")
        precondition(sameTrackFormat == first)
        let formatCount = await transport.count
        precondition(formatCount == 1)
        try Data("<html>not audio</html>".utf8).write(to: first)
        let repaired = try await cache.store(asset, trackID: "netease:42")
        precondition(repaired == first)
        let repairedData = try Data(contentsOf: repaired)
        precondition(repairedData == expected)
        let repairedCount = await transport.count
        precondition(repairedCount == 2)
        let qq = try await cache.store(asset, trackID: "qq-music:42")
        precondition(qq != first)
        let qqCount = await transport.count
        precondition(qqCount == 3)
        let pending = try await client.prepare(trackID: "netease:hash-negative", fileExtension: "mp3", requestID: "hash-request")
        let action = pending.actionID!
        let claimed = try await client.claim(actionID: action)
        try expected.write(to: URL(fileURLWithPath: claimed.stagePath!), options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: claimed.stagePath!)
        do {
            _ = try await client.receipt(actionID: action, sha256: String(repeating: "0", count: 64),
                bytes: UInt64(expected.count), audioValid: true)
            fatalError("incorrect hash accepted")
        } catch {}
        let sha = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
        let done = try await client.receipt(actionID: action, sha256: sha, bytes: UInt64(expected.count), audioValid: true)
        precondition(done.state == "ready")
        let duplicate = try await client.receipt(actionID: action, sha256: sha, bytes: UInt64(expected.count), audioValid: true)
        precondition(duplicate.state == "ready")
        let invalidPlan = try await client.prepare(trackID: "netease:forged-audio", fileExtension: "mp3", requestID: "invalid-audio-request")
        let invalidClaim = try await client.claim(actionID: invalidPlan.actionID!)
        let html = Data("<html>audioValid true is not proof</html>".utf8)
        try html.write(to: URL(fileURLWithPath: invalidClaim.stagePath!), options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: invalidClaim.stagePath!)
        let htmlSHA = SHA256.hash(data: html).map { String(format: "%02x", $0) }.joined()
        do {
            _ = try await client.receipt(actionID: invalidPlan.actionID!, sha256: htmlSHA,
                bytes: UInt64(html.count), audioValid: true)
            fatalError("native audioValid bypassed Rust content validation")
        } catch {}
        precondition(!FileManager.default.fileExists(atPath: invalidClaim.finalPath!))
        print("PASS actual Swift cache: headers/hit/corruption/QQ/hash-negative/duplicate; downloads=3")
    }
}
