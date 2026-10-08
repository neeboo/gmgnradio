import Foundation
#if GMGN_STORAGE_FULL_MODULE
#if GMGN_STORAGE_RELEASE_TYPECHECK
import UnityMediaHost
#else
@testable import UnityMediaHost
#endif
#else
enum PropTaskJSON: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: Self]), array([Self]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode(Double.self) { self = .number(x) }
        else if let x = try? c.decode([String: Self].self) { self = .object(x) }
        else { self = .array(try c.decode([Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let x): try c.encode(x)
        case .number(let x): try c.encode(x)
        case .bool(let x): try c.encode(x)
        case .object(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .null: try c.encodeNil()
        }
    }
}
enum PropTaskDaemonError: Error { case invalidFrame }
@MainActor final class PropTaskDaemonClient {
    init(root: URL? = nil, helperURL: URL? = nil, requestTimeout: TimeInterval = 10) { }
    func call(method: String, params: [String: PropTaskJSON]) async throws -> [String: PropTaskJSON] { fatalError("Fixture must not access a live daemon") }
}
#endif
enum MusicStorageFixtureError: Error { case unavailable, revisionConflict }
@MainActor final class MusicStorageRPCFixture {
    var programs: [SavedDJProgram] = []
    var pending: [String] = []
    var playlists: [MusicPlaylistSnapshot] = []
    var revision = 0
    var rejected = false
    lazy var client = MusicStorageClient(includeDefaultLegacy: false, call: call)
    func encode<T: Encodable>(_ value: T) throws -> PropTaskJSON {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(PropTaskJSON.self, from: e.encode(value))
    }
    func decode<T: Decodable>(_ value: PropTaskJSON, as: T.Type) throws -> T {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(T.self, from: JSONEncoder().encode(value))
    }
    func call(_ method: String, _ params: [String: PropTaskJSON]) async throws -> [String: PropTaskJSON] {
        if rejected { throw MusicStorageFixtureError.unavailable }
        if method.hasPrefix("music_library_") || method.hasPrefix("music_dj_") || method.hasPrefix("music_program_") || method == "music_import" {
            guard let endpoint = ProcessInfo.processInfo.environment["GMGN_MUSIC_LIBRARY_FIXTURE_URL"],
                  let url = URL(string: endpoint), ["127.0.0.1", "localhost"].contains(url.host ?? ""),
                  let token = ProcessInfo.processInfo.environment["GMGN_MUSIC_LIBRARY_FIXTURE_TOKEN"] else {
                throw MusicStorageFixtureError.unavailable
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(PropTaskJSON.object([
                "jsonrpc": .string("2.0"), "id": .string(UUID().uuidString),
                "method": .string(method), "params": .object(params)]))
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  case .object(let envelope) = try JSONDecoder().decode(PropTaskJSON.self, from: data),
                  envelope["error"] == nil, case .object(let result) = envelope["result"] else {
                throw MusicStorageFixtureError.unavailable
            }
            return result
        }
        fatalError("Unexpected private music RPC")
    }
}
