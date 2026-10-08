import Foundation

enum CodexTrackRankingError: Error, LocalizedError {
    case invalidResponse
    var errorDescription: String? { "Codex 没有返回可用的节目排序。" }
}

/// Trusted preferences/transport configuration only. Prompt generation, model
/// execution, parsing, fallback and track selection belong to Rust.
struct CodexTrackRankingAgent: DJShowPlanningAgent, DJPlanningConfigurationProviding {
    private let hostPrompt: String
    private let model: String?
    private let client: RustMusicProgramClient?
    init(hostPrompt: String, model: String? = nil, client: RustMusicProgramClient? = nil) {
        self.hostPrompt = hostPrompt; self.model = model; self.client = client
    }
    @MainActor static func live(preferences: DJAgentPreferences? = nil) throws -> CodexTrackRankingAgent {
        let preferences = preferences ?? DJAgentPreferences()
        return .init(hostPrompt: preferences.hostPrompt(), model: preferences.planningModel())
    }
    var planningConfiguration: DJPlanningConfiguration {
        let allowed = Set(["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "OPENAI_API_KEY"])
        var environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        return .init(hostPrompt: hostPrompt, executable: CodexProcessRunner.locate()?.path,
                     environment: environment, model: model)
    }
    @MainActor func rankTracks(brief: ProgramBrief, candidates: [MusicCandidate]) async throws -> [String] {
        try await (client ?? RustMusicProgramClient()).rankedIDs(brief: brief, candidates: candidates, configuration: planningConfiguration)
    }
    @MainActor func proposeShow(brief: ProgramBrief, candidates: [MusicCandidate]) async throws -> AgentShowProposal {
        try await (client ?? RustMusicProgramClient()).modelProposal(brief: brief, candidates: candidates, configuration: planningConfiguration)
    }
}
