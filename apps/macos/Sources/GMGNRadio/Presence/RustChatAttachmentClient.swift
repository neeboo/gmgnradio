import Foundation

/// Native supplies verified preparation facts; SQLite owns draft/submission refs.
actor RustChatAttachmentClient {
    struct Identity: Sendable { let ownerID: String; let hostSessionID: String }
    struct Attachment: Decodable, Sendable {
        let id: String; let localPath: String; let displayName: String
        let sha256: String; let byteCount: UInt64; let frameGeneration: UInt64
    }
    struct Snapshot: Decodable, Sendable {
        let revision: UInt64; let frameGeneration: UInt64
        let attachments: [Attachment]; let canSend: Bool
    }
    struct Reply: Decodable, Sendable {
        let snapshot: Snapshot; let deletePaths: [String]
        let submission: Submission?
    }
    struct Submission: Decodable, Sendable {
        let submissionID: String; let attachmentIDs: [String]
        let hasText: Bool; let state: String
    }
    typealias Call = @Sendable (String, Data) throws -> Data
    private let call: Call
    init(call: @escaping Call) { self.call = call }
    init(endpointFile: String, helperPath: String, allowsLaunching: Bool = true) {
        let transport = TaskdHTTPAuthorityClient(endpointFile:endpointFile,helperPath:helperPath,
            allowsLaunching:allowsLaunching,timeout:10)
        call = { method, data in
            let values = try JSONSerialization.jsonObject(with:data) as! [String:Any]
            return try JSONSerialization.data(withJSONObject:transport.call(method:method,params:values))
        }
    }
    private func request(_ identity: Identity, _ method: String, _ values: [String:Any] = [:]) async throws -> Reply {
        var params = values
        params["ownerID"] = identity.ownerID; params["hostSessionID"] = identity.hostSessionID
        let data = try JSONSerialization.data(withJSONObject:params); let call = self.call
        let response = try await Task.detached {try call(method,data)}.value
        return try JSONDecoder().decode(Reply.self,from:response)
    }
    func open(_ identity: Identity, directory: String) async throws -> Reply {
        try await request(identity,"chat_attachments_open",["directory":directory])
    }
    func read(_ identity: Identity, submissionID: UUID? = nil) async throws -> Reply {
        try await request(identity,"chat_attachments_read",submissionID.map {
            ["submissionID":$0.uuidString.lowercased()]
        } ?? [:])
    }
    func register(_ identity: Identity, revision: UInt64, frameGeneration: UInt64, attachmentID: UUID,
                  localPath: String, sha256: String, byteCount: Int, displayName: String) async throws -> Reply {
        try await request(identity,"chat_attachments_register",["expectedRevision":revision,
            "frameGeneration":frameGeneration,"attachmentID":attachmentID.uuidString.lowercased(),"localPath":localPath,
            "sha256":sha256,"byteCount":byteCount,"displayName":displayName])
    }
    func remove(_ identity: Identity, revision: UInt64, attachmentID: UUID) async throws -> Reply {
        try await request(identity,"chat_attachments_remove",["expectedRevision":revision,"attachmentID":attachmentID.uuidString.lowercased()])
    }
    func take(_ identity: Identity, revision: UInt64, submissionID: UUID, attachmentIDs: [UUID], hasText: Bool) async throws -> Reply {
        try await request(identity,"chat_attachments_take",["expectedRevision":revision,
            "submissionID":submissionID.uuidString.lowercased(),"attachmentIDs":attachmentIDs.map {$0.uuidString.lowercased()},"hasText":hasText])
    }
    func restore(_ identity: Identity, revision: UInt64, submissionID: UUID) async throws -> Reply {
        try await request(identity,"chat_attachments_restore",["expectedRevision":revision,"submissionID":submissionID.uuidString.lowercased()])
    }
    func finish(_ identity: Identity, revision: UInt64, submissionID: UUID, state: String) async throws -> Reply {
        try await request(identity,"chat_attachments_finish",["expectedRevision":revision,"submissionID":submissionID.uuidString.lowercased(),"state":state])
    }
    func close(_ identity: Identity, revision: UInt64) async throws -> Reply {try await request(identity,"chat_attachments_close",["expectedRevision":revision])}
}
