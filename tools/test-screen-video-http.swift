import Foundation
import AVFoundation

final class RejectedMedia: URLProtocol {
    static let lock = NSLock()
    nonisolated(unsafe) static var validRequest = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.validRequest = request.value(forHTTPHeaderField: "Range") == "bytes=0-1" && request.value(forHTTPHeaderField: "User-Agent") == "fixture-player" && request.value(forHTTPHeaderField: "Cookie") == nil }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("Forbidden".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class RangeLimitedMedia: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let parts = (request.value(forHTTPHeaderField: "Range") ?? "").replacingOccurrences(of: "bytes=", with: "").split(separator: "-").compactMap { Int($0) }
        let valid = parts.count == 2 && parts[1] - parts[0] + 1 <= 1_048_576 && parts[1] < 4_741_786
        let response = HTTPURLResponse(url: request.url!, statusCode: valid ? 206 : 403, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum HTTPCheck {
    static func main() async throws {
        guard ScreenLinkAssetLoader.chunkSize == 1_048_576 else { fatalError("Media Range exceeds proven public-source cap") }
        let chunk = ScreenLinkAssetLoader.boundedChunkLength
        guard chunk(4_741_786, Int64.max, 4_741_786) == 0,
              chunk(4_194_304, Int64.max, 4_741_786) == 547_482,
              chunk(0, 100, 4_741_786) == 100,
              chunk(0, Int64.max, nil) == 1_048_576,
              chunk(0, 4_194_304, 4_741_786) == 1_048_576 else { fatalError("Production EOF/tail/remaining/unknown-length Range bounds failed") }
        let limits = URLSessionConfiguration.ephemeral; limits.protocolClasses = [RangeLimitedMedia.self]
        let rangeSession = URLSession(configuration: limits)
        for (length, expected) in [(4_194_304, 403), (1_048_576, 206)] {
            var request = URLRequest(url: URL(string: "https://fixture.invalid/video")!); request.setValue("bytes=0-\(length-1)", forHTTPHeaderField: "Range")
            let (_, response) = try await rangeSession.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == expected else { fatalError("Range fixture did not enforce public-source cap") }
        }
        rangeSession.invalidateAndCancel()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RejectedMedia.self]
        let url = URL(string: "https://fixture.invalid/video.mp4?signed=never-log")!
        let loader = ScreenLinkAssetLoader(originalURL: url, headers: ["User-Agent": "fixture-player"], configuration: configuration)
        let asset = AVURLAsset(url: ScreenLinkAssetLoader.customURL(for: url)!)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "screen-http-fixture"))
        do { _ = try await asset.loadTracks(withMediaType: .video); fatalError("Rejected HTTP media unexpectedly loaded") }
        catch { }
        guard loader.lastHTTPStatus == 403, RejectedMedia.lock.withLock({ RejectedMedia.validRequest }) else { fatalError("Lost HTTP status or required request shape") }
        print("PASS: actual AVAssetResourceLoader HTTP 403 retained, two-byte Range, header forwarding, no cookies")
    }
}
