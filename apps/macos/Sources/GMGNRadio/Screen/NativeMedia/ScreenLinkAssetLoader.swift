import AVFoundation
import Foundation

// MARK: - 给 AVPlayer 的媒体请求带上**服务端要求的请求头**

/// 解析器给的媒体地址常常要求一组请求头（YouTube 的 `User-Agent` / `Accept-Language`
/// 之类）。`AVURLAsset` 的私有 `AVURLAssetHTTPHeaderFieldsKey` 在新系统上**不可靠**
/// （真机 2026-10-03 实测：直接用它，`loadTracks` 报 `NSURLErrorDomain#-1102`；同一组
/// 头用 curl 取是 206）。
///
/// 所以这里走 **公开的** `AVAssetResourceLoaderDelegate`：把 asset 的 URL 换成一个自定义
/// scheme，AVFoundation 就会把每个媒体请求交给我们；我们再用 `URLSession`（**不使用任何
/// cookie / 缓存**）带头发出去，把内容信息与字节按它要求的 Range 回填。
///
/// 两个实现要点，都是真机实测换来的：
/// 1. **不能一次要整个文件**：同一个 googlevideo 地址，`Range: bytes=0-1048575` 是 206，
///    而 `bytes=0-2000000000`（接近整文件）直接 **403 text/plain**。所以一个大的数据请求
///    必须拆成有界块顺序回填（`chunkSize`），而不是照抄它要的长度发一次。
/// 2. **跨域跳转要重带请求头**：视频地址常见 302 到另一台 googlevideo 主机，不重带就 403。
///
/// 它不读浏览器 cookies、不代持凭据：`URLSessionConfiguration.ephemeral` +
/// `httpShouldSetCookies = false`，请求头只来自解析器的 `ScreenLinkStream.headers`
/// （解析器已经把 `Cookie` / `Authorization` 结构上剥掉了）。
final class ScreenLinkAssetLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionTaskDelegate,
    @unchecked Sendable
{
    /// 给 AVFoundation 看的自定义 scheme。它只活在内存里，永不落盘。
    static let scheme = "gmgnstream"
    /// 每次向源站取的有界块大小。见类型注释：整文件 Range 会被 403。
    static let chunkSize: Int64 = 4 * 1024 * 1024

    private let originalURL: URL
    private let headers: [String: String]
    /// 诊断标签（格式 id）。**不是地址**。
    private let tag: String
    private var session: URLSession!
    /// 开发诊断（`GMGN_SCREEN_LINK_DEBUG=1`）：只打印请求形状与响应头，**从不打印地址**。
    private let debugEnabled =
        ProcessInfo.processInfo.environment["GMGN_SCREEN_LINK_DEBUG"] == "1"

    init(originalURL: URL, headers: [String: String], tag: String = "") {
        self.originalURL = originalURL
        self.headers = headers
        self.tag = tag
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// 把真实地址换成自定义 scheme 的地址。失败返回 `nil`（那时调用方退回直连）。
    static func customURL(for original: URL) -> URL? {
        guard var components = URLComponents(url: original, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = scheme
        return components.url
    }

    private static func originalURL(from custom: URL) -> URL? {
        guard var components = URLComponents(url: custom, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = "https"
        return components.url
    }

    /// 把 `AVAssetResourceLoadingRequest` 包一层，好让它在 `@Sendable` 的网络回调之间传递。
    private final class RequestBox: @unchecked Sendable {
        let request: AVAssetResourceLoadingRequest
        let target: URL
        init(_ request: AVAssetResourceLoadingRequest, target: URL) {
            self.request = request
            self.target = target
        }
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let requestURL = loadingRequest.request.url,
              let target = Self.originalURL(from: requestURL)
        else { return false }
        let box = RequestBox(loadingRequest, target: target)
        if let info = loadingRequest.contentInformationRequest {
            // 先用 2 字节探内容信息（Content-Type / 总长度 / 是否支持 Range）。
            fetch(target: target, offset: 0, length: 2) { [weak self] response, _ in
                guard let self else { return }
                if let response {
                    if let mime = response.mimeType { info.contentType = mime }
                    info.isByteRangeAccessSupported = response.statusCode == 206
                        || (response.value(forHTTPHeaderField: "Accept-Ranges")?.contains("bytes") ?? false)
                    info.contentLength = Self.totalLength(from: response) ?? response.expectedContentLength
                }
                if let dataRequest = loadingRequest.dataRequest {
                    self.serve(box, dataRequest: dataRequest)
                } else {
                    loadingRequest.finishLoading()
                }
            }
        } else if let dataRequest = loadingRequest.dataRequest {
            serve(box, dataRequest: dataRequest)
        } else {
            loadingRequest.finishLoading()
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        // 每个 `loadingRequest` 的续块在每一步都会检查 `isCancelled`，会自行停下。
    }

    // MARK: URLSessionTaskDelegate

    /// 跨域跳转（googlevideo 的地址常见 302）也要把请求头带过去，否则目标会 403。
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        for (key, value) in headers { redirected.setValue(value, forHTTPHeaderField: key) }
        completionHandler(redirected)
    }

    // MARK: 有界块顺序回填

    private func serve(_ box: RequestBox, dataRequest: AVAssetResourceLoadingDataRequest) {
        let requestedLength = Int64(dataRequest.requestedLength)
        let toEnd = dataRequest.requestsAllDataToEndOfResource
        // 从 AVFoundation 要求的偏移开始；它自己会用 `currentOffset` 跟踪我们回填了多少。
        serveChunk(
            box, dataRequest: dataRequest, offset: dataRequest.requestedOffset,
            remaining: toEnd ? Int64.max : requestedLength
        )
    }

    private func serveChunk(
        _ box: RequestBox,
        dataRequest: AVAssetResourceLoadingDataRequest,
        offset: Int64,
        remaining: Int64
    ) {
        let request = box.request
        guard !request.isCancelled, remaining > 0 else {
            request.finishLoading()
            return
        }
        let length = min(remaining == Int64.max ? Self.chunkSize : remaining, Self.chunkSize)
        fetch(target: box.target, offset: offset, length: length) { [weak self] response, data in
            guard let self else { return }
            guard !request.isCancelled else { request.finishLoading(); return }
            guard let data, !data.isEmpty else {
                // 源站没有更多字节（或出错）：按 AVFoundation 的语义就是到此为止。
                request.finishLoading()
                return
            }
            // 200（服务器忽略 Range）时只有第一块能直接用；后续块需要自己切片。
            let slice: Data
            if response?.statusCode == 200, offset > 0 {
                let start = Int(min(offset, Int64(data.count)))
                slice = start < data.count ? data.subdata(in: start..<data.count) : Data()
            } else {
                slice = data
            }
            guard !slice.isEmpty else { request.finishLoading(); return }
            dataRequest.respond(with: slice)
            let advanced = Int64(slice.count)
            let nextRemaining = remaining == Int64.max ? Int64.max : remaining - advanced
            self.serveChunk(
                box, dataRequest: dataRequest, offset: offset + advanced, remaining: nextRemaining
            )
        }
    }

    @discardableResult
    private func fetch(
        target: URL, offset: Int64, length: Int64,
        completion: @escaping @Sendable (HTTPURLResponse?, Data?) -> Void
    ) -> URLSessionDataTask {
        var request = URLRequest(url: target)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let end = offset + max(length, 1) - 1
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request) { [debugEnabled, tag] data, response, error in
            if debugEnabled {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let mime = (response as? HTTPURLResponse)?.mimeType ?? "-"
                let message = "RESLOAD tag=\(tag) offset=\(offset) length=\(length) status=\(status) "
                    + "mime=\(mime) bytes=\(data?.count ?? 0) "
                    + "error=\((error as NSError?)?.code ?? 0)\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
            completion(response as? HTTPURLResponse, data)
        }
        task.resume()
        return task
    }

    private static func totalLength(from response: HTTPURLResponse) -> Int64? {
        guard let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
              let slash = contentRange.lastIndex(of: "/")
        else { return nil }
        let total = contentRange[contentRange.index(after: slash)...]
        return Int64(total)
    }
}
