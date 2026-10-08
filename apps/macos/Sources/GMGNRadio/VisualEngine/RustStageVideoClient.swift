import Foundation

actor RustStageVideoClient {
    typealias Call = @Sendable (String,Data) throws -> Data
    struct Entry: Codable, Sendable, Equatable { let entryID: String; let assetID: String }
    struct Action: Decodable, Sendable {
        let actionID: String; let hostSessionID: String; let generation: UInt64
        let kind: String; let mode: String; let entries: [Entry]; let executionStatus: String
        let executorInstanceID: String?
    }
    struct Playback: Decodable, Sendable {
        let hostSessionID: String?; let generation: UInt64; let queue: [Entry]
        let active: Bool; let paused: Bool; let mode: String?
    }
    struct Prompt: Decodable, Sendable { let id: String; let trackID: String; let trackTitle: String; let assetID: String }
    struct State: Decodable, Sendable {
        let assets: [StageVideoAsset]; let bindings: [String:String]; let selectedAssetID: String?
        let enabled: Bool; let mode: StageVideoPlaybackMode; let brightness: Float
        let rankedIDs: [String]; let temporaryBoundTrackID: String?; let pendingBoundVideo: Prompt?
        let playback: Playback; let pendingAction: Action?
    }
    struct Snapshot: Decodable, Sendable { let revision: UInt64; let state: State; let replayed: Bool? }
    struct Command: Encodable, Sendable {
        let op: String
        var assetID: String?; var trackID: String?; var trackTitle: String?; var promptID: String?
        var mode: String?; var brightness: Float?; var mood: String?; var role: String?
        var assets: [StageVideoAsset]?; var actionID: String?; var generation: UInt64?; var entryID: String?
        var executorInstanceID: String?; var queueEmpty: Bool?; var rateZero: Bool?
    }
    struct Legacy: Encodable, Sendable {
        let assets: [StageVideoAsset]; let bindings: [String:String]; let selectedAssetID: String?
        let enabled: Bool?; let mode: String?; let brightness: Float?
    }
    let hostSessionID: String
    private let scope: String
    private let call: Call
    private var revision: UInt64 = 0
    private var requests: [String:(method:String,body:Data,bytes:Data)] = [:]
    init(call: @escaping Call, scope: String, hostSessionID: String) {
        self.call=call; self.scope=scope; self.hostSessionID=hostSessionID
    }
    init(endpointFile: String, helperPath: String, allowsLaunching: Bool, scope: String, hostSessionID: String) {
        self.scope=scope; self.hostSessionID=hostSessionID
        let transport=TaskdHTTPAuthorityClient(endpointFile:endpointFile,helperPath:helperPath,allowsLaunching:allowsLaunching,timeout:5)
        call={ method,bytes in
            guard let params=try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else {throw WorldAuthorityError.invalidResponse}
            return try JSONSerialization.data(withJSONObject:transport.call(method:method,params:params))
        }
    }
    private func request<T: Encodable & Sendable>(_ method:String,body:T,requestID:String=UUID().uuidString) async throws -> Snapshot {
        let call=self.call, scope=self.scope, host=self.hostSessionID, expected=revision
        let encoded=try await Task.detached {let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return try e.encode(body)}.value
        let bytes:Data
        if let previous=requests[requestID] {
            guard previous.method==method,previous.body==encoded else {throw WorldAuthorityError.daemon("request_id_conflict")}
            bytes=previous.bytes
        } else {
            bytes=try await Task.detached {
            guard var params=try JSONSerialization.jsonObject(with:encoded) as? [String:Any] else {throw WorldAuthorityError.invalidResponse}
            params["scope"]=scope;params["hostSessionID"]=host;params["requestID"]=requestID;params["expectedRevision"]=expected
            return try JSONSerialization.data(withJSONObject:params,options:[.sortedKeys])
            }.value
            requests[requestID]=(method,encoded,bytes)
        }
        let result=try await Task.detached {
            return try JSONDecoder().decode(Snapshot.self,from:call(method,bytes))
        }.value
        revision=result.revision;return result
    }
    func read() async throws -> Snapshot {
        struct Empty: Encodable, Sendable {}
        return try await request("stage_video_read",body:Empty())
    }
    func importLegacy(_ value:Legacy) async throws -> Snapshot {try await request("stage_video_import",body:value)}
    func command(_ command:Command,requestID:String=UUID().uuidString) async throws -> Snapshot {
        try await request("stage_video_command",body:command,requestID:requestID)
    }
    func claim(_ action:Action) async throws -> Snapshot {
        try await command(Command(op:"claimAction",actionID:action.actionID,generation:action.generation),requestID:"stage-claim-"+action.actionID)
    }
    func receipt(_ action:Action,accepted:Bool) async throws -> Snapshot {
        struct Receipt: Encodable, Sendable {let actionID:String;let generation:UInt64;let accepted:Bool}
        return try await request("stage_video_receipt",body:Receipt(actionID:action.actionID,generation:action.generation,accepted:accepted),requestID:"stage-receipt-"+action.actionID)
    }
}
