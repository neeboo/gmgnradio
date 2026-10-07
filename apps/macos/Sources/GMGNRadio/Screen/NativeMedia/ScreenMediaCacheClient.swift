import Foundation

enum ScreenMediaCacheState: String, Decodable, Sendable {
    case queued, resolving, downloading, streaming, ready, failed, cancelled, missing, interrupted, evicted
    var panelText: String {
        switch self {
        case .queued: "正在排队缓存"
        case .resolving: "正在解析视频"
        case .downloading: "正在缓冲视频"
        case .streaming: "直播流已连接"
        case .ready: "视频已缓存，正在出画"
        case .failed: "视频缓存失败"
        case .cancelled: "视频缓存已取消"
        case .missing: "视频缓存文件缺失"
        case .interrupted: "视频缓存已中断"
        case .evicted: "视频缓存已清理"
        }
    }
}

struct ScreenMediaCacheStatus: Sendable {
    let cacheKey: String
    let state: ScreenMediaCacheState
    let descriptor: NativeScreenMediaDescriptor?
    let errorCode: String?
}

protocol ScreenMediaCaching: Sendable {
    func prepare(pageURL: String, maxHeight: Int, consumerID: String) async throws -> ScreenMediaCacheStatus
    func status(cacheKey: String) async throws -> ScreenMediaCacheStatus
    func release(cacheKey: String, consumerID: String) async throws
    func cancel(cacheKey: String, consumerID: String) async throws
    func importPlaylist(pageURL: String, playlistID: String) async throws -> ScreenVideoPlaylist
    func advancePlaylist(playlistID: String, revision: Int) async throws -> ScreenVideoPlaylist
    func releasePlaylist(playlistID: String) async throws
}

struct ScreenVideoPlaylist: Decodable, Sendable {
    struct Item: Decodable, Sendable { let pageURL: String }
    let playlistID: String
    let revision: Int
    let currentIndex: Int
    let items: [Item]
    let truncated: Bool?
    let itemLimit: Int?
    var currentURL: String? { items.indices.contains(currentIndex) ? items[currentIndex].pageURL : nil }
    var hasNext: Bool { currentIndex + 1 < items.count }
}

extension ScreenMediaCaching {
    func importPlaylist(pageURL: String, playlistID: String) async throws -> ScreenVideoPlaylist { throw ScreenMediaCacheError.unavailable }
    func advancePlaylist(playlistID: String, revision: Int) async throws -> ScreenVideoPlaylist { throw ScreenMediaCacheError.unavailable }
    func releasePlaylist(playlistID: String) async throws {}
}

enum ScreenMediaCacheError: Error, Sendable {
    case unavailable, invalidResponse, invalidDescriptor, missingFile, noAudio, server(String)

    var code: String {
        switch self {
        case .unavailable: "media_cache_unavailable"
        case .invalidResponse: "media_cache_invalid_response"
        case .invalidDescriptor: "media_cache_invalid_descriptor"
        case .missingFile: "media_cache_file_missing"
        case .noAudio: "media_cache_audio_missing"
        case let .server(code): Self.safeCode(code)
        }
    }
    var panelText: String {
        switch self {
        case .unavailable: return "视频缓存服务未连接，暂时放不了。"
        case .missingFile: return "已缓存的视频文件找不到了，请重新播放。"
        case .noAudio: return "这条视频没有可播放的声音。"
        case .invalidResponse, .invalidDescriptor: return "视频缓存回执异常，暂时放不了。"
        case let .server(code):
            if code == "media_playlist_start_outside_limit" {return "起播视频超出本次列表范围：普通列表最多200条，Mix最多50条。"}
            if code == "media_playlist_empty" || code == "media_playlist_unavailable" {return "这份播放列表暂时读不到可播放的视频。"}
            return code.contains("helper") ? "视频缓存缺少可用的取流组件，暂时放不了。" : "这条视频缓存失败，请重新播放。"
        }
    }
    static func safeCode(_ code: String) -> String {
        guard !code.isEmpty, code.utf8.count <= 96,
              code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 })
        else { return "media_cache_failed" }
        return code
    }
}

/// Only the existing authenticated taskd HTTP endpoint is used. Rust owns fetching,
/// cache files and eviction; this client never launches a helper or downloads remote media.
actor ScreenMediaCacheClient: ScreenMediaCaching {
    nonisolated static func isYouTubePlaylist(_ page: String) -> Bool {
        guard let url=URLComponents(string: page), url.scheme == "https",
              ["youtube.com","www.youtube.com","m.youtube.com","music.youtube.com","youtu.be"].contains(url.host?.lowercased() ?? ""),
              let list=url.queryItems?.first(where: {$0.name == "list"})?.value else {return false}
        return !list.isEmpty && list.utf8.count <= 200 && list.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    /// taskd stores canonical page identities, not the original share URL.
    /// Retain the identity check while allowing host aliases and tracking queries.
    nonisolated static func samePage(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard let left = pageIdentity(lhs), let right = pageIdentity(rhs) else { return false }
        return left == right
    }

    private nonisolated static func pageIdentity(_ raw: String) -> String? {
        guard let url = URLComponents(string: raw), url.scheme == "https",
              url.user == nil, url.password == nil, url.port == nil, let host = url.host else { return nil }
        switch host {
        case "youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be":
            let id: String?
            if host == "youtu.be" { id = String(url.path.dropFirst()) }
            else if url.path == "/watch" { id = url.queryItems?.first(where: { $0.name == "v" })?.value }
            else if url.path.hasPrefix("/shorts/") { id = String(url.path.dropFirst(8)) }
            else { id = nil }
            guard let id, id.utf8.count == 11,
                  id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
            return "youtube:\(id)"
        case "bilibili.com", "www.bilibili.com", "m.bilibili.com":
            let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
            guard path.hasPrefix("/video/") else { return nil }
            let id = String(path.dropFirst(7))
            guard id.count <= 64, id.hasPrefix("BV") || id.hasPrefix("av"),
                  id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
            if let part = url.queryItems?.first(where: { $0.name == "p" }) {
                guard let rawPart = part.value, let number = UInt32(rawPart), (1...1000).contains(number) else { return nil }
                return "bilibili:\(id):\(number)"
            }
            return "bilibili:\(id)"
        default: return nil
        }
    }

    private struct Endpoint: Decodable { let version: Int; let address: String; let token: String }
    private struct FailureDTO: Decodable {
        let code: String
        init(from decoder: Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(String.self) { code = value }
            else {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                code = try values.decode(String.self, forKey: .code)
            }
        }
        private enum CodingKeys: String, CodingKey { case code }
    }
    private struct Envelope: Decodable { let id: String; let result: StatusDTO?; let error: FailureDTO? }
    private struct Acknowledgement: Decodable { let id: String; let error: FailureDTO? }
    private struct StatusDTO: Decodable {
        let cacheKey: String
        let state: ScreenMediaCacheState
        let descriptor: DescriptorDTO?
        let streamingDescriptor: DescriptorDTO?
        let error: FailureDTO?
    }
    private struct DescriptorDTO: Decodable {
        let pageURL: String
        let site: ScreenLinkSite
        let title: String
        let durationSeconds: Double?
        let isLive: Bool
        let video: StreamDTO
        let audio: StreamDTO?

        func native(endpoint: Endpoint? = nil) throws -> NativeScreenMediaDescriptor {
            guard video.hasVideo, video.hasAudio || audio?.hasAudio == true else {
                if !video.hasAudio && audio?.hasAudio != true { throw ScreenMediaCacheError.noAudio }
                throw ScreenMediaCacheError.invalidDescriptor
            }
            var streams = [try video.native(endpoint: endpoint)]
            if let audio {
                guard !audio.hasVideo else { throw ScreenMediaCacheError.invalidDescriptor }
                streams.append(try audio.native(endpoint: endpoint))
            }
            return NativeScreenMediaDescriptor(pageURL: pageURL, title: title, site: site, isLive: isLive,
                streams: streams, note: "Rust local media cache", durationSeconds: durationSeconds)
        }
    }
    private struct StreamDTO: Decodable {
        let url: String
        let formatID: String
        let container: String?
        let videoCodec: String?
        let audioCodec: String?
        let width: Int?
        let height: Int?
        let isManifest: Bool
        let hasVideo: Bool
        let hasAudio: Bool
        let headers: [String: String]

        func native(endpoint: Endpoint? = nil) throws -> NativeScreenMediaStream {
            if let endpoint {
                let liveParts = url.split(separator: "/", omittingEmptySubsequences: true)
                if liveParts.count == 3, liveParts[0] == "media-live",
                   liveParts.dropFirst().allSatisfy({
                       guard let id = UUID(uuidString: String($0)) else { return false }
                       return id.uuidString.dropFirst(14).first == "4"
                   }),
                   url == "/" + liveParts.joined(separator: "/"), headers.isEmpty,
                   let local = URL(string: "http://\(endpoint.address)\(url)") {
                    return NativeScreenMediaStream(url: local.absoluteString, formatID: formatID,
                        headers: [:], isVideo: hasVideo, isAudio: hasAudio, isManifest: isManifest)
                }
                guard url.hasPrefix("/media/"), !url.hasPrefix("//"), headers.isEmpty,
                      let parts = URLComponents(string: url), parts.scheme == nil, parts.host == nil,
                      parts.fragment == nil, !parts.path.split(separator: "/").contains(".."),
                      let local = URL(string: "http://\(endpoint.address)\(url)") else {
                    throw ScreenMediaCacheError.invalidDescriptor
                }
                return NativeScreenMediaStream(url: local.absoluteString, formatID: formatID,
                    headers: ["Authorization": "Bearer \(endpoint.token)"],
                    isVideo: hasVideo, isAudio: hasAudio, isManifest: isManifest)
            }
            guard let file = URL(string: url), file.isFileURL, file.host == nil || file.host == "" || file.host == "localhost",
                  file.query == nil, file.fragment == nil, !file.path.isEmpty,
                  !isManifest, headers.isEmpty else { throw ScreenMediaCacheError.invalidDescriptor }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &directory), !directory.boolValue else {
                throw ScreenMediaCacheError.missingFile
            }
            return NativeScreenMediaStream(url: file.absoluteString, formatID: formatID, headers: [:],
                isVideo: hasVideo, isAudio: hasAudio, isManifest: false)
        }
    }

    private let endpointFile: URL
    private let timeout: TimeInterval
    init(endpointFile: URL? = nil, timeout: TimeInterval = 10) {
        self.endpointFile = endpointFile ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gmgn radio/TaskService/taskd.endpoint.json")
        self.timeout = timeout
    }

    func prepare(pageURL: String, maxHeight: Int, consumerID: String) async throws -> ScreenMediaCacheStatus {
        try await rpc("media_prepare", params: ["pageURL": pageURL, "maxHeight": maxHeight, "pin": true, "consumerID": consumerID])
    }
    func status(cacheKey: String) async throws -> ScreenMediaCacheStatus {
        try await rpc("media_status", params: ["cacheKey": cacheKey])
    }
    func release(cacheKey: String, consumerID: String) async throws {
        _ = try await rpc("media_release", params: ["cacheKey": cacheKey, "consumerID": consumerID], expectsStatus: false)
    }
    func cancel(cacheKey: String, consumerID: String) async throws {
        _ = try await rpc("media_cancel", params: ["cacheKey": cacheKey, "consumerID": consumerID], expectsStatus: false)
    }
    func importPlaylist(pageURL: String, playlistID: String) async throws -> ScreenVideoPlaylist {
        try await playlistRPC("media_playlist_import", params: ["pageURL":pageURL,"playlistID":playlistID,"baseRevision":0])
    }
    func advancePlaylist(playlistID: String, revision: Int) async throws -> ScreenVideoPlaylist {
        try await playlistRPC("media_playlist_advance", params:["playlistID":playlistID,"baseRevision":revision])
    }
    func releasePlaylist(playlistID: String) async throws {
        _ = try await rpc("media_playlist_release",params:["playlistID":playlistID],expectsStatus:false)
    }
    private func playlistRPC(_ method: String, params: [String:Any]) async throws -> ScreenVideoPlaylist {
        let (body,_,id)=try await transport(method,params:params,requestTimeout:100)
        struct Reply: Decodable {let id:String;let result:ScreenVideoPlaylist?;let error:FailureDTO?}
        guard let reply=try? JSONDecoder().decode(Reply.self,from:body),reply.id == id else {throw ScreenMediaCacheError.invalidResponse}
        if let error=reply.error {throw ScreenMediaCacheError.server(error.code)}
        guard let result=reply.result,result.playlistID == params["playlistID"] as? String,
              result.revision > 0, !result.items.isEmpty,result.items.count <= 200,result.currentURL != nil,
              result.items.allSatisfy({Self.pageIdentity($0.pageURL)?.hasPrefix("youtube:") == true}) else {throw ScreenMediaCacheError.invalidResponse}
        return result
    }

    private func rpc(_ method: String, params: [String: Any], expectsStatus: Bool = true) async throws -> ScreenMediaCacheStatus {
        let (body,endpoint,id)=try await transport(method,params:params,requestTimeout:timeout)
        return try decodeStatus(body,endpoint:endpoint,id:id,params:params,expectsStatus:expectsStatus)
    }
    private func transport(_ method:String,params:[String:Any],requestTimeout:TimeInterval) async throws -> (Data,Endpoint,String) {
        guard let data = try? Data(contentsOf: endpointFile),
              let endpoint = try? JSONDecoder().decode(Endpoint.self, from: data) else { throw ScreenMediaCacheError.unavailable }
        let parts = endpoint.address.split(separator: ":")
        guard endpoint.version == 2, parts.count == 2, parts[0] == "127.0.0.1",
              let port = UInt16(parts[1]), port > 0,
              let token = UUID(uuidString: endpoint.token), token.uuidString.dropFirst(14).first == "4" else {
            throw ScreenMediaCacheError.invalidResponse
        }
        let id = UUID().uuidString
        var request = URLRequest(url: URL(string: "http://\(endpoint.address)/rpc")!, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        let body: Data
        do {
            // Do not abandon prepare's response on task cancellation: a bounded reply
            // provides the cache key needed to release a pin accepted by the daemon.
            body = try await withCheckedThrowingContinuation { continuation in
                let transport = TaskdHTTPTransport(streaming: false, maximumBytes: 256 * 1024,
                    receive: { continuation.resume(returning: $0) }, completion: { error in
                        if let error { continuation.resume(throwing: error) }
                    })
                transport.start(request)
            }
        } catch let TaskdHTTPError.rejected(code) { throw ScreenMediaCacheError.server(code) }
        catch { throw ScreenMediaCacheError.unavailable }
        return (body,endpoint,id)
    }
    private func decodeStatus(_ body:Data,endpoint:Endpoint,id:String,params:[String:Any],expectsStatus:Bool) throws -> ScreenMediaCacheStatus {
        if !expectsStatus {
            guard let reply = try? JSONDecoder().decode(Acknowledgement.self, from: body), reply.id == id else {
                throw ScreenMediaCacheError.invalidResponse
            }
            if let error = reply.error { throw ScreenMediaCacheError.server(error.code) }
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], object["result"] != nil else {
                throw ScreenMediaCacheError.invalidResponse
            }
            return ScreenMediaCacheStatus(cacheKey: params["cacheKey"] as? String ?? "", state: .ready, descriptor: nil, errorCode: nil)
        }
        guard let response = try? JSONDecoder().decode(Envelope.self, from: body), response.id == id else {
            throw ScreenMediaCacheError.invalidResponse
        }
        if let error = response.error { throw ScreenMediaCacheError.server(error.code) }
        guard let result = response.result, !result.cacheKey.isEmpty else { throw ScreenMediaCacheError.invalidResponse }
        var descriptor: NativeScreenMediaDescriptor?
        var errorCode = result.error.map { ScreenMediaCacheError.safeCode($0.code) }
        if result.state == .downloading || result.state == .streaming, let streaming = result.streamingDescriptor {
            do { descriptor = try streaming.native(endpoint: endpoint) }
            catch let error as ScreenMediaCacheError { errorCode = error.code }
            catch { errorCode = ScreenMediaCacheError.invalidDescriptor.code }
        } else if result.state == .ready {
            do {
                guard let ready = result.descriptor else { throw ScreenMediaCacheError.invalidDescriptor }
                descriptor = try ready.native()
            } catch let error as ScreenMediaCacheError { errorCode = error.code }
            catch { errorCode = ScreenMediaCacheError.invalidDescriptor.code }
        }
        return ScreenMediaCacheStatus(cacheKey: result.cacheKey, state: result.state,
            descriptor: descriptor, errorCode: errorCode)
    }
}
