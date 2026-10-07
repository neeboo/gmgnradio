import Foundation

/// Signed media addresses and header values arrive on stdin and are never printed.
@main enum NativeHTTPShape {
    struct Stream: Decodable { let url: String; let id: String; let headers: [String: String] }
    static func main() async throws {
        let streams = try JSONDecoder().decode([Stream].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for stream in streams {
            guard let original = URL(string: stream.url), var components = URLComponents(url: original, resolvingAgainstBaseURL: false) else { continue }
            components.scheme = "gmgn-screen-media"; components.scheme = "https"
            print("format=\(stream.id) customSchemeRoundTripIdentical=\(components.url?.absoluteString == original.absoluteString)")
            for length in [2, 1_048_576, 4_194_304] {
                var request = URLRequest(url: original)
                for (key, value) in stream.headers { request.setValue(value, forHTTPHeaderField: key) }
                request.setValue("bytes=0-\(length - 1)", forHTTPHeaderField: "Range")
                do {
                    let (data, response) = try await session.data(for: request)
                    let http = response as? HTTPURLResponse
                    print("format=\(stream.id) range=\(length) status=\(http?.statusCode ?? -1) bytes=\(data.count) contentRange=\(http?.value(forHTTPHeaderField: "Content-Range") ?? "none")")
                } catch { print("format=\(stream.id) range=\(length) transportCode=\((error as NSError).code)") }
            }
        }
    }
}
