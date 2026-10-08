import Foundation
import Darwin

actor RustMusicCacheClient {
    typealias Call = @Sendable (String, Data) throws -> Data
    struct View: Decodable, Sendable {
        let state: String
        let key: String
        let actionID: String?
        let stagePath: String?
        let finalPath: String?
        let sha256: String?
        let bytes: UInt64?
    }
    private let call: Call
    private let hostSessionID: String
    let directory: URL

    init(endpointFile: String, helperPath: String, allowsLaunching: Bool,
         taskRoot: URL, hostSessionID: String) {
        let transport = TaskdHTTPAuthorityClient(endpointFile: endpointFile, helperPath: helperPath,
            allowsLaunching: allowsLaunching, timeout: 60)
        call = { method, data in
            guard let params = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WorldAuthorityError.invalidResponse
            }
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: params))
        }
        self.hostSessionID = hostSessionID
        directory = Self.cacheDirectory(taskRoot)
    }
    init(call: @escaping Call, taskRoot: URL, hostSessionID: String) {
        self.call = call; self.hostSessionID = hostSessionID
        directory = Self.cacheDirectory(taskRoot)
    }
    private static func cacheDirectory(_ root: URL) -> URL {
        guard let path = realpath(root.path, nil) else {
            return root.standardizedFileURL.appendingPathComponent("MusicCache", isDirectory: true)
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
            .appendingPathComponent("MusicCache", isDirectory: true)
    }
    private func request(_ method: String, _ fields: [String: String], bytes: UInt64? = nil,
                         audioValid: Bool? = nil) async throws -> View {
        var params: [String: Any] = fields
        params["hostSessionID"] = hostSessionID
        if let bytes { params["bytes"] = bytes }
        if let audioValid { params["audioValid"] = audioValid }
        let data = try JSONSerialization.data(withJSONObject: params)
        let call = self.call
        let response = try await Task.detached { try call(method, data) }.value
        return try JSONDecoder().decode(View.self, from: response)
    }
    func prepare(trackID: String, fileExtension: String, requestID: String) async throws -> View {
        let provider = trackID.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        return try await request("music_cache_prepare", ["providerID": provider, "trackID": trackID,
            "extension": fileExtension, "requestID": requestID])
    }
    func read(actionID: String) async throws -> View {
        try await request("music_cache_read", ["actionID": actionID])
    }
    func claim(actionID: String) async throws -> View {
        try await request("music_cache_claim", ["actionID": actionID])
    }
    func receipt(actionID: String, sha256: String, bytes: UInt64, audioValid: Bool) async throws -> View {
        try await request("music_cache_receipt", ["actionID": actionID, "outcome": "completed",
            "sha256": sha256], bytes: bytes, audioValid: audioValid)
    }
    func failed(actionID: String) async throws -> View {
        try await request("music_cache_receipt", ["actionID": actionID, "outcome": "failed"])
    }
}
