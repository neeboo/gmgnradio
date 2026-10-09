import Foundation

enum TaskdHTTPError: Error {
    /// 传输层异常但拿不到更细的原因（例如响应根本不是 HTTP）。
    case unavailable
    case invalidFrame
    case timedOut
    case rejected(code: String)
    /// 对端在**没有传输错误**的情况下结束了响应体（事件流 EOF，或连接被复用方关闭）。
    /// 这不是"权威不可达"：订阅端应当立刻从游标续上，调用方也不该把它报给用户。
    case streamEnded
    /// 连接层失败（非超时）。带上 `URLError.Code` 的原始值，让"连接失败"与
    /// "正常流结束"在日志里能分开。
    case connectionFailed(code: Int)
    /// 非 200 且 body 里没有 `error.code`。带上 status：以前这条和"连接断了"
    /// 折叠成同一句话，真机上没法区分是服务端拒绝了还是链路抖了。
    case httpStatus(Int)
}

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
    /// 事件流的**空闲**上限（秒）。
    ///
    /// 为什么要有它、而且不能是调用方的 RPC 预算：`URLRequest.timeoutInterval`
    /// 对 URLSession 是"这次请求多久没有新数据就算超时"，它同样作用于一条长期
    /// 存活的 SSE。权威每 15 秒发一次 `: heartbeat`（`services/gmgn-taskd/src/http.rs`
    /// 的 `Events::poll_next`），而订阅用的客户端预算只有 5 秒 ⇒ 客户端每 5 秒把
    /// 自己**健康**的订阅流按"请求超时"掐断一次，退避后重连，日志里就是那条
    /// 每 ~40 秒一次的"世界状态权威不可达：HTTP connection ended"
    /// （隔离复现：`timeout=2` → 2.11s 断、`timeout=8` → 8.03s 断、
    /// `timeout=20` → 活过 40 秒探针上限）。心跳间隔的 4 倍既容得下心跳抖动，
    /// 也能在链路真的静默时 60 秒内发现并重连。
    static let streamingIdleTimeout: TimeInterval = 60
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
        var request = request
        // 请求自己的 `timeoutInterval` 会盖掉会话配置，所以流式请求必须在这里改：
        // 见 `streamingIdleTimeout` 的注释。
        if streaming { request.timeoutInterval = Self.streamingIdleTimeout }
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
            } else { completion(TaskdHTTPError.httpStatus(status)) }
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
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: finish(TaskdHTTPError.timedOut)
            // 我们自己 `cancel()` 引发的 -999 不是故障；`finish` 的 once 语义
            // 通常已经先把它挡掉了，这里再挡一次，避免把主动收尾记成连接失败。
            case .cancelled: finish(nil)
            default: finish(TaskdHTTPError.connectionFailed(code: urlError.errorCode))
            }
            return
        }
        if let error { finish(error); return }
        // 没有传输错误：事件流被对端收尾（服务端关闭 / 连接池回收 / 正常 EOF）。
        // 这**不是**"权威不可达"——订阅端据此立即从游标重连，调用方不报错。
        finish(acceptingEvents ? TaskdHTTPError.streamEnded : nil)
    }
}
