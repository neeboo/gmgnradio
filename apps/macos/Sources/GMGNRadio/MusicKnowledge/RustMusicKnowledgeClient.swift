import Foundation

actor RustMusicKnowledgeClient {
    typealias Call = @Sendable (String, Data) throws -> Data
    struct Snapshot: Codable, Sendable { let revision: Int64; let tracks: [TrackKnowledge] }
    enum ClientError: Error { case invalidProtocol }
    static let live: RustMusicKnowledgeClient = {
        let root = WorldAuthorityEndpoint.taskServiceRoot()
        let transport = TaskdHTTPAuthorityClient(endpointFile: root.appendingPathComponent("taskd.endpoint.json").path,
            helperPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gmgn-taskd").path,
            allowsLaunching: false, timeout: 5)
        return RustMusicKnowledgeClient(scope: root.appendingPathComponent("music-knowledge").path) { method, data in
            guard let params = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClientError.invalidProtocol }
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: params))
        }
    }()
    private let call: Call
    let scope: String
    init(scope: String, call: @escaping Call) { self.scope = scope; self.call = call }
    private func request(_ method: String, fields: [String: Any]) async throws -> Snapshot {
        var params = fields; params["scope"] = scope
        if method != "music_knowledge_read", params["requestID"] == nil { params["requestID"] = UUID().uuidString }
        let data = try JSONSerialization.data(withJSONObject: params); let call = self.call
        let output = try await Task.detached { try call(method, data) }.value
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Snapshot.self, from: output)
    }
    @discardableResult
    func ingest(_ candidates: [MusicCandidate], origin: MusicLibraryOrigin, seenAt: Date,
                requestID: String = UUID().uuidString) async throws -> Snapshot {
        // This is raw provider data, never a merged TrackKnowledge proposal.
        let rows = try candidates.map { candidate -> [String: Any] in
            guard var row = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as? [String: Any] else { throw ClientError.invalidProtocol }
            row["providerID"] = candidate.providerID.rawValue
            return row
        }
        return try await request("music_knowledge_ingest", fields: ["requestID": requestID,
            "candidates": rows, "origin": origin.rawValue, "seenAt": seenAt.timeIntervalSince1970 * 1000])
    }
    @discardableResult
    func record(_ event: MusicListeningEvent, requestID: String = UUID().uuidString) async throws -> Snapshot {
        var fields: [String: Any] = ["requestID": requestID, "trackID": event.trackID]
        switch event {
        case let .played(_, completed, at): fields["event"] = "played"; fields["completed"] = completed; fields["at"] = at.timeIntervalSince1970 * 1000
        case let .completed(_, at): fields["event"] = "completed"; fields["at"] = at.timeIntervalSince1970 * 1000
        case let .skipped(_, at): fields["event"] = "skipped"; fields["at"] = at.timeIntervalSince1970 * 1000
        case let .liked(_, isLiked, at): fields["event"] = "liked"; fields["isLiked"] = isLiked; fields["at"] = at.timeIntervalSince1970 * 1000
        }
        return try await request("music_knowledge_event", fields: fields)
    }
    func read() async throws -> Snapshot { try await request("music_knowledge_read", fields: [:]) }
}
