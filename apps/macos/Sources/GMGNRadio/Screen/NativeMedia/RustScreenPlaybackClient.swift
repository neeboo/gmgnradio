import Foundation

struct RustScreenPlaybackTicket: Decodable, Sendable {
    let worldID: String
    let screenID: String
    let hostSessionID: String
    let sessionID: String
    let generation: UInt64
    let pageURL: String
    let playlist: ScreenVideoPlaylist?
}
struct RustScreenPlaybackState: Decodable, Sendable {
    let worldID: String
    let screenID: String
    let hostSessionID: String
    let sessionID: String
    let generation: UInt64
    let status: String
    let pageURL: String
    let originalURL: String
    let playlist: ScreenVideoPlaylist?
}
struct RustScreenPlaybackReply: Decodable, Sendable {
    let state: RustScreenPlaybackState
    let ticket: RustScreenPlaybackTicket?
    let duplicate: Bool
}
protocol ScreenPlaybackAuthorizing: Sendable {
    func begin(worldID: String, screenID: String, pageURL: String, isPlaylist: Bool, requestID: String) async throws -> RustScreenPlaybackReply
    func read(worldID: String, screenID: String) async throws -> RustScreenPlaybackReply
    func receipt(_ ticket: RustScreenPlaybackTicket, status: String, isLive: Bool, requestID: String) async throws -> RustScreenPlaybackReply
    func stop(_ ticket: RustScreenPlaybackTicket, requestID: String) async throws -> RustScreenPlaybackReply
}

/// No decoder, queue cursor, playlist writer, helper launcher or remote media access.
actor RustScreenPlaybackClient: ScreenPlaybackAuthorizing {
    private struct Endpoint: Decodable { let version: Int; let address: String; let token: String }
    private struct Failure: Decodable { let code: String }
    private struct Envelope: Decodable { let id: String; let result: RustScreenPlaybackReply?; let error: Failure? }
    private let endpointFile: URL
    private let hostSessionID = UUID().uuidString
    init(endpointFile: URL? = nil) {
        self.endpointFile = endpointFile ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gmgn radio/TaskService/taskd.endpoint.json")
    }
    private func call(_ method: String, _ input: [String: Any]) async throws -> RustScreenPlaybackReply {
        guard let data = try? Data(contentsOf: endpointFile), let endpoint = try? JSONDecoder().decode(Endpoint.self, from: data) else { throw ScreenMediaCacheError.unavailable }
        let parts = endpoint.address.split(separator: ":")
        guard endpoint.version == 2, parts.count == 2, parts[0] == "127.0.0.1", let port = UInt16(parts[1]), port > 0,
              let token = UUID(uuidString: endpoint.token), token.uuidString.dropFirst(14).first == "4" else { throw ScreenMediaCacheError.invalidResponse }
        let id = UUID().uuidString
        var params = input; params["hostSessionID"] = hostSessionID
        var request = URLRequest(url: URL(string: "http://\(endpoint.address)/rpc")!, timeoutInterval: method == "screen_playback_begin" ? 100 : 10)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        let body: Data = try await withCheckedThrowingContinuation { continuation in
            let transport = TaskdHTTPTransport(streaming: false, maximumBytes: 512 * 1024,
                receive: { continuation.resume(returning: $0) }, completion: { error in if let error { continuation.resume(throwing: error) } })
            transport.start(request)
        }
        let reply = try JSONDecoder().decode(Envelope.self, from: body)
        guard reply.id == id else { throw ScreenMediaCacheError.invalidResponse }
        if let error = reply.error { throw ScreenMediaCacheError.server(error.code) }
        guard let result = reply.result, result.state.worldID == input["worldID"] as? String,
              result.state.screenID == input["screenID"] as? String, result.state.hostSessionID == hostSessionID else { throw ScreenMediaCacheError.invalidResponse }
        if let ticket = result.ticket {
            guard ticket.worldID == result.state.worldID, ticket.screenID == result.state.screenID,
                  ticket.hostSessionID == hostSessionID, ticket.sessionID == result.state.sessionID,
                  ticket.generation == result.state.generation, ticket.pageURL == result.state.pageURL else { throw ScreenMediaCacheError.invalidResponse }
        }
        return result
    }
    func begin(worldID: String, screenID: String, pageURL: String, isPlaylist: Bool, requestID: String) async throws -> RustScreenPlaybackReply {
        try await call("screen_playback_begin", ["worldID":worldID,"screenID":screenID,"pageURL":pageURL,"isPlaylist":isPlaylist,"requestID":requestID])
    }
    func read(worldID: String, screenID: String) async throws -> RustScreenPlaybackReply {
        try await call("screen_playback_read", ["worldID":worldID,"screenID":screenID])
    }
    private func identity(_ ticket: RustScreenPlaybackTicket, requestID: String) throws -> [String: Any] {
        guard ticket.hostSessionID == hostSessionID else { throw ScreenMediaCacheError.invalidResponse }
        return ["worldID":ticket.worldID,"screenID":ticket.screenID,"sessionID":ticket.sessionID,"generation":ticket.generation,"pageURL":ticket.pageURL,"requestID":requestID]
    }
    func receipt(_ ticket: RustScreenPlaybackTicket, status: String, isLive: Bool, requestID: String) async throws -> RustScreenPlaybackReply {
        var params = try identity(ticket, requestID: requestID); params["status"] = status; params["isLive"] = isLive
        do { return try await call("screen_playback_receipt", params) }
        catch let error as ScreenMediaCacheError { throw error }
        catch {
            // Lost HTTP response may hide an already committed EOF. Reuse the
            // exact durable request; never synthesize a second EOF or new begin.
            return try await call("screen_playback_receipt", params)
        }
    }
    func stop(_ ticket: RustScreenPlaybackTicket, requestID: String) async throws -> RustScreenPlaybackReply {
        try await call("screen_playback_stop", identity(ticket, requestID: requestID))
    }
}
