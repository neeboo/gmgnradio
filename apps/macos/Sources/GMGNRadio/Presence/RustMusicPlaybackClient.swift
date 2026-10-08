import Foundation

@MainActor final class RustMusicPlaybackClient {
    struct Entry: Codable, Equatable { let id: String; let payload: Data }
    struct State: Codable {
        let generation: UInt64
        let sessionID: String
        let hostSessionID: String
        let mode: String
        let queue: [Entry]
        let index: Int
        let status: String
        let pending: Ticket?
    }
    struct Ticket: Codable {
        let generation: UInt64
        let requestID: String
        let hostSessionID: String
        let queue: [Entry]
        let index: Int
        let mode: String
        let trackID: String
    }
    private struct Reply: Decodable { let state: State; let ticket: Ticket? }
    private let transport: TaskdHTTPAuthorityClient
    let hostSessionID = UUID().uuidString
    private let playerID = "unity.main.music"
    private(set) var state: State?
    private var projections: [String: Any] = [:]
    var onError: ((Error) -> Void)?
    var onCommitted: (() -> Void)?
    var onCommitRejected: ((Ticket) -> Void)?
    init(root: URL) {
        let endpoint = WorldAuthorityEndpoint(applicationSupportBase: root)
        transport = TaskdHTTPAuthorityClient(endpointFile: endpoint.endpointFile, helperPath: endpoint.helperPath,
            allowsLaunching: false, timeout: 1)
    }
    @discardableResult private func call(_ method: String, _ params: [String: Any]) throws -> Reply {
        var params = params; params["playerID"] = playerID; params["hostSessionID"] = hostSessionID
        let reply = try JSONDecoder().decode(Reply.self,
            from: JSONSerialization.data(withJSONObject: transport.call(method: method, params: params)))
        if state?.mode != reply.state.mode || state?.queue != reply.state.queue { projections.removeAll() }
        state = reply.state
        return reply
    }
    private func payload<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    func begin<T: Encodable>(queue: [T], ids: [String], index: Int, mode: String) throws -> Ticket {
        guard queue.count == ids.count else { throw WorldAuthorityError.invalidResponse }
        let entries = try zip(queue, ids).map { Entry(id: $0.1, payload: try payload($0.0)) }
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entries))
        guard let ticket = try call("music_playback_begin", ["requestID": UUID().uuidString,
            "queue": value, "index": index, "mode": mode]).ticket else { throw WorldAuthorityError.invalidResponse }
        return ticket
    }
    func navigate(delta: Int? = nil, slotIndex: Int? = nil, trackID: String? = nil) throws -> Ticket {
        guard let state else { throw WorldAuthorityError.invalidResponse }
        var params: [String: Any] = ["sessionID": state.sessionID, "requestID": UUID().uuidString]
        if let delta { params["delta"] = delta }
        if let slotIndex { params["slotIndex"] = slotIndex }
        if let trackID { params["trackID"] = trackID }
        guard let ticket = try call("music_playback_navigate", params).ticket else { throw WorldAuthorityError.invalidResponse }
        return ticket
    }
    func commit(_ ticket: Ticket, accepted: Bool) throws {
        do {
            _ = try call("music_playback_commit", ["generation": ticket.generation, "requestID": ticket.requestID,
                "trackID": ticket.trackID, "accepted": accepted])
            if accepted { onCommitted?() }
        } catch { if accepted { onCommitRejected?(ticket) }; throw error }
    }
    func isCurrent(_ ticket: Ticket) throws -> Bool {
        let reply = try call("music_playback_read", [:])
        return reply.state.pending?.requestID == ticket.requestID && reply.state.pending?.generation == ticket.generation
    }
    func receipt(status: String, sessionID: String, trackID: String) throws {
        _ = try call("music_playback_receipt", ["sessionID": sessionID, "trackID": trackID, "status": status])
    }
    func clear(mode: String) throws {
        guard let state, state.mode == mode, !state.queue.isEmpty else { return }
        _ = try call("music_playback_clear", ["sessionID": state.sessionID])
    }
    func replaceUpcoming<T: Encodable>(queue: [T], ids: [String]) throws {
        guard let state, queue.count == ids.count else { throw WorldAuthorityError.invalidResponse }
        let entries = try zip(queue, ids).map { Entry(id: $0.1, payload: try payload($0.0)) }
        _ = try call("music_playback_replace_upcoming", ["sessionID": state.sessionID,
            "queue": JSONSerialization.jsonObject(with: JSONEncoder().encode(entries))])
    }
    func items<T: Decodable>(mode: String, as: T.Type) -> [T] {
        guard let state, state.mode == mode else { return [] }
        let key = mode + String(reflecting: T.self)
        if let cached = projections[key] as? [T] { return cached }
        do {
            let decoded = try state.queue.map { try JSONDecoder().decode(T.self, from: $0.payload) }
            projections[key] = decoded
            return decoded
        }
        catch { onError?(error); return [] }
    }
}

/// Value projections only. Selection identity, indices and publication come from Rust.
@MainActor final class RustMusicSelectionProjection<Item: Codable> {
    struct Ticket { let authority: RustMusicPlaybackClient.Ticket; let queue: [Item]; let index: Int }
    let client: RustMusicPlaybackClient
    private let identity: (Item) -> String
    init(client: RustMusicPlaybackClient, identity: @escaping (Item) -> String) {
        self.client = client; self.identity = identity
    }
    var queue: [Item] { client.items(mode: "library", as: Item.self) }
    var index: Int { client.state?.mode == "library" ? client.state?.index ?? 0 : 0 }
    func begin(queue: [Item], index: Int) -> Ticket? {
        do {
            let receipt = try client.begin(queue: queue, ids: queue.map(identity), index: index, mode: "library")
            return Ticket(authority: receipt, queue: queue, index: receipt.index)
        } catch { client.onError?(error); return nil }
    }
    func commit(_ ticket: Ticket, accepted: Bool) -> Bool {
        do { try client.commit(ticket.authority, accepted: accepted); return accepted }
        catch { client.onError?(error); return false }
    }
    func isCurrent(_ ticket: Ticket) -> Bool {
        do { return try client.isCurrent(ticket.authority) }
        catch { client.onError?(error); return false }
    }
    func clear() {
        do { try client.clear(mode: "library") } catch { client.onError?(error) }
    }
}
