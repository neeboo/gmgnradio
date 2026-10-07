import Foundation

enum TaskdHTTPError: Error { case unavailable, invalidFrame, timedOut, rejected(code: String) }

/// The daemon verifies the signed bundle's expected hashes before executing either helper.
/// No user PATH, runtime discovery, or browser configuration participates in media caching.
enum TaskdBundledMediaConfiguration {
    static func arguments(nextTo daemonURL: URL) -> [String] {
        let directory = daemonURL.deletingLastPathComponent()
        let video = directory.appendingPathComponent("yt-dlp")
        let runtime = directory.appendingPathComponent("deno")
        guard directory.isFileURL,
              FileManager.default.isExecutableFile(atPath: video.path),
              FileManager.default.isExecutableFile(atPath: runtime.path),
              let videoHash = expectedHash(for: video),
              let runtimeHash = expectedHash(for: runtime) else { return [] }
        return ["--media-helper", video.path, "--media-helper-sha256", videoHash,
                "--media-deno", runtime.path, "--media-deno-sha256", runtimeHash]
    }

    private static func expectedHash(for helper: URL) -> String? {
        guard let data = try? Data(contentsOf: helper.appendingPathExtension("sha256")),
              data.count <= 256,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let fields = text.split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 2, fields[1] == Substring(helper.lastPathComponent) else { return nil }
        let value = String(fields[0])
        guard value.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return value
    }
}

/// A bounded URLSession transport. URLSession owns HTTP framing and cancellation.
final class TaskdHTTPTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maxBytes = 12 * 1024 * 1024
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var finished = false
    private var statusCode = 0
    private var acceptingEvents = false
    private let streaming: Bool
    private let maximumBytes: Int
    private let receive: @Sendable (Data) -> Void
    private let completion: @Sendable (Error?) -> Void
    init(streaming: Bool, maximumBytes: Int = TaskdHTTPTransport.maxBytes,
         receive: @escaping @Sendable (Data) -> Void, completion: @escaping @Sendable (Error?) -> Void) {
        self.streaming = streaming; self.receive = receive; self.completion = completion
        self.maximumBytes = min(Self.maxBytes, max(1, maximumBytes))
    }
    func start(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = streaming ? 7 * 24 * 3600 : request.timeoutInterval
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session; let task = session.dataTask(with: request); self.task = task; task.resume()
    }
    func cancel() { finish(CancellationError()) }
    func pause() { lock.lock(); task?.suspend(); lock.unlock() }
    func resume() { lock.lock(); task?.resume(); lock.unlock() }
    private func finish(_ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let session = session; self.session = nil; task = nil
        let body = buffer; let status = statusCode; buffer.removeAll(); lock.unlock()
        session?.invalidateAndCancel()
        if error == nil && status != 200 {
            if let envelope = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let failure = envelope["error"] as? [String: Any], let code = failure["code"] as? String {
                completion(TaskdHTTPError.rejected(code: code))
            } else { completion(TaskdHTTPError.unavailable) }
            return
        }
        if error == nil && !streaming { receive(body) }
        completion(error)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(TaskdHTTPError.unavailable); return
        }
        lock.lock(); statusCode = http.statusCode; acceptingEvents = streaming && http.statusCode == 200; lock.unlock()
        guard acceptingEvents || response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel); finish(TaskdHTTPError.invalidFrame); return
        }
        if acceptingEvents && http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") != true {
            completionHandler(.cancel); finish(TaskdHTTPError.invalidFrame); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        buffer.append(data)
        if !acceptingEvents {
            let overflow = buffer.count > maximumBytes; lock.unlock()
            if overflow { finish(TaskdHTTPError.invalidFrame) }; return
        }
        var frames: [Data] = []
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            if line.count > maximumBytes { lock.unlock(); finish(TaskdHTTPError.invalidFrame); return }
            frames.append(line)
        }
        let overflow = buffer.count > maximumBytes; lock.unlock()
        if overflow { finish(TaskdHTTPError.invalidFrame); return }
        for frame in frames { receive(frame) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let urlError = error as? URLError, urlError.code == .timedOut { finish(TaskdHTTPError.timedOut) }
        else { finish(error ?? (acceptingEvents ? TaskdHTTPError.unavailable : nil)) }
    }
}
