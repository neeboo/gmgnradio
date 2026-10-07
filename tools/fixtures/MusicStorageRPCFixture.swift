import Foundation
#if GMGN_STORAGE_FULL_MODULE
@testable import UnityMediaHost
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
    init(root: URL? = nil, helperURL: URL? = nil) { }
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
        switch method {
        case "music_program_save":
            let item = try decode(params["program"]!, as: SavedDJProgram.self)
            programs.removeAll { $0.plan.brief.id == item.plan.brief.id }; programs.insert(item, at: 0)
            pending.removeAll { $0 == item.plan.brief.id }
            if params["pending"] == .bool(true) { pending.append(item.plan.brief.id) }
            return ["saved": .bool(true)]
        case "music_program_list": return ["programs": try encode(programs), "pendingIDs": try encode(pending)]
        case "music_library_read": return ["playlists": try encode(playlists), "revision": .number(Double(revision))]
        case "music_library_commit":
            guard params["baseRevision"] == .number(Double(revision)) else { throw MusicStorageFixtureError.revisionConflict }
            playlists = try decode(params["playlists"]!, as: [MusicPlaylistSnapshot].self); revision += 1
            return ["playlists": try encode(playlists), "revision": .number(Double(revision))]
        case "music_import": fatalError("Fixtures must not import production legacy files")
        default: fatalError("Unexpected music RPC")
        }
    }
}
