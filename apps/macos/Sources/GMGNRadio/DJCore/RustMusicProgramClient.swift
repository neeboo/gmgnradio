import Foundation

struct DJPlanningConfiguration: Sendable {
    let hostPrompt: String
    let executable: String?
    let environment: [String: String]
    let model: String?
}

/// Native projection only; Rust owns construction and state transitions.
@MainActor final class RustMusicProgramClient {
    typealias Call = @MainActor (String, [String: PropTaskJSON]) async throws -> [String: PropTaskJSON]
    struct View: Decodable {
        let revision: UInt64
        let programs: [SavedDJProgram]
        let pendingIDs: [String]
        let plan: ProgramPlan?
        let pendingPlan: ProgramPlan?
        let activeSlotIndex: Int?
        let selectedPlan: ProgramPlan?
    }
    struct Discovery: Decodable { let discoveryQuery: String?; let targetEnergy: Double? }
    private let call: Call
    private var revision: UInt64?
    private var operation: Task<View, Error>?
    init(root: URL? = nil, helperURL: URL? = nil, call: Call? = nil) {
        let daemon = PropTaskDaemonClient(root: root, helperURL: helperURL, requestTimeout: 200)
        self.call = call ?? { try await daemon.call(method: $0, params: $1) }
    }
    private func payload<T: Encodable>(_ value: T) throws -> PropTaskJSON {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(PropTaskJSON.self, from: encoder.encode(value))
    }
    private func decode<T: Decodable>(_ reply: [String: PropTaskJSON], as: T.Type) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: JSONEncoder().encode(reply))
    }
    func read() async throws -> View {
        if let operation { _ = try? await operation.value }
        let view = try decode(await call("music_dj_read", [:]), as: View.self)
        revision = max(revision ?? 0, view.revision); return view
    }
    func command(_ op: String, programID: String? = nil, index: Int? = nil,
                 proposalID: String? = nil, mode: String? = nil) async throws -> View {
        let previous = operation
        let task = Task { @MainActor [self] in
            if let previous { _ = try? await previous.value }
            if revision == nil {
                let view = try decode(await call("music_dj_read", [:]), as: View.self)
                revision = view.revision
            }
            var params: [String: PropTaskJSON] = ["op": .string(op), "expectedRevision": .number(Double(revision!))]
            if let programID { params["programID"] = .string(programID) }
            if let index { params["index"] = .number(Double(index)) }
            if let proposalID { params["proposalID"] = .string(proposalID) }
            if let mode { params["mode"] = .string(mode) }
            let view = try decode(await call("music_dj_command", params), as: View.self)
            revision = view.revision; return view
        }
        operation = task; return try await task.value
    }
    func flush() async throws { _ = try await operation?.value }
    func discover(brief: ProgramBrief) async throws -> Discovery {
        try decode(await call("music_dj_discovery", ["brief": try payload(brief)]), as: Discovery.self)
    }
    func dailyBrief(instruction: String?) async throws -> ProgramBrief {
        struct Reply: Decodable { let brief: ProgramBrief }
        var params: [String: PropTaskJSON] = ["dailyBrief": .bool(true)]
        if let instruction { params["instruction"] = .string(instruction) }
        return try decode(await call("music_dj_discovery", params), as: Reply.self).brief
    }
    func playlistPlan(playlistID: String) async throws -> ProgramPlan {
        try decode(await call("music_dj_playlist_plan", ["playlistID": .string(playlistID)]), as: ProgramPlan.self)
    }
    func candidates(brief: ProgramBrief, knowledge: [TrackKnowledge]) async throws -> CandidatePool {
        try decode(await call("music_dj_candidates", ["brief": try payload(brief), "knowledge": try payload(knowledge)]), as: CandidatePool.self)
    }
    func modelProposal(brief: ProgramBrief, candidates: [MusicCandidate], configuration: DJPlanningConfiguration) async throws -> AgentShowProposal {
        try decode(await modelProjection(brief: brief, candidates: candidates, configuration: configuration, mode: "proposal"), as: AgentShowProposal.self)
    }
    func rankedIDs(brief: ProgramBrief, candidates: [MusicCandidate], configuration: DJPlanningConfiguration) async throws -> [String] {
        struct Ranked: Decodable { let trackIDs: [String] }
        return try decode(await modelProjection(brief: brief, candidates: candidates, configuration: configuration, mode: "ranked"), as: Ranked.self).trackIDs
    }
    private func modelProjection(brief: ProgramBrief, candidates: [MusicCandidate], configuration: DJPlanningConfiguration, mode: String) async throws -> [String: PropTaskJSON] {
        var params: [String: PropTaskJSON] = ["brief": try payload(brief), "discoveryCandidates": try payload(candidates), "libraryCandidates": .array([]), "hostPrompt": .string(configuration.hostPrompt), "environment": try payload(configuration.environment), "outputMode": .string(mode)]
        if let executable = configuration.executable { params["executable"] = .string(executable) }
        if let model = configuration.model { params["model"] = .string(model) }
        return try await call("music_dj_plan", params)
    }
    func plan(brief: ProgramBrief, discoveryCandidates: [MusicCandidate], libraryCandidates: [MusicCandidate], hostPrompt: String,
              executable: String? = nil, environment: [String: String] = [:], model: String? = nil) async throws -> ProgramPlan {
        var params: [String: PropTaskJSON] = ["brief": try payload(brief), "discoveryCandidates": try payload(discoveryCandidates), "libraryCandidates": try payload(libraryCandidates), "hostPrompt": .string(hostPrompt), "environment": try payload(environment)]
        if let executable { params["executable"] = .string(executable) }
        if let model { params["model"] = .string(model) }
        return try decode(await call("music_dj_plan", params), as: ProgramPlan.self)
    }
}
