import Foundation
import Testing
@testable import GMGNRadio

/// Every test owns its daemon, SQLite file and mock CLI; no production root,
/// credentials, provider or audio device is used.
@MainActor final class PrivateMusicAuthorityFixture {
    let root: URL
    private let process: Process
    private let daemon: PropTaskDaemonClient
    var rejected = false
    private var executable: URL?
    var prompt: String? { try? String(contentsOf: root.appendingPathComponent("prompt.txt"), encoding: .utf8) }
    var capturedSchema: String? { try? String(contentsOf: root.appendingPathComponent("schema.json"), encoding: .utf8) }
    var capturedArguments: [String] { (try? String(contentsOf: root.appendingPathComponent("arguments.txt"), encoding: .utf8))?.split(separator: "\n").map(String.init) ?? [] }
    lazy var client = RustMusicProgramClient(call: call)
    lazy var storage = MusicStorageClient(includeDefaultLegacy: false, call: call)
    var call: RustMusicProgramClient.Call { { [weak self] method, input in
        guard let self else { throw PropTaskDaemonError.unavailable }
        if rejected { throw PropTaskDaemonError.unavailable }
        var params = input
        if method == "music_dj_plan" {
            params.removeValue(forKey: "executable")
            if let executable { params["executable"] = .string(executable.path) }
            params["environment"] = .object(["PATH": .string("/usr/bin:/bin")])
        }
        return try await daemon.call(method: method, params: params)
    } }
    private init(root: URL, process: Process, binary: URL) {
        self.root = root; self.process = process
        daemon = PropTaskDaemonClient(root: root, helperURL: binary, allowsLaunching: false)
    }
    static func start() async throws -> PrivateMusicAuthorityFixture {
        let env = ProcessInfo.processInfo.environment
        guard let binary = env["GMGN_TASKD_TEST_BINARY"] ?? env["TASKD_BIN"],
              FileManager.default.isExecutableFile(atPath: binary) else { throw PropTaskDaemonError.helperMissing }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("gmgn-dj-unit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let child = Process(); child.executableURL = URL(fileURLWithPath: binary)
        child.arguments = ["--root",root.path,"--endpoint-file",root.appendingPathComponent("taskd.endpoint.json").path,"--concurrency","1"]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        let fixture = PrivateMusicAuthorityFixture(root: root, process: child, binary: URL(fileURLWithPath: binary))
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("taskd.endpoint.json").path) { return fixture }
            guard child.isRunning else { throw PropTaskDaemonError.unavailable }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PropTaskDaemonError.unavailable
    }
    func mockOutput(_ output: String) throws {
        let outputFile = root.appendingPathComponent("model.json")
        try Data(output.utf8).write(to: outputFile)
        let script = root.appendingPathComponent("mock-codex")
        let text = """
        #!/bin/sh
        set -eu
        out=''
        schema=''
        printf '%s\\n' "$@" > '\(root.appendingPathComponent("arguments.txt").path)'
        while [ $# -gt 0 ]; do
          case "$1" in --output-last-message) shift; out=$1;; --output-schema) shift; schema=$1;; esac
          shift
        done
        cat > '\(root.appendingPathComponent("prompt.txt").path)'
        cp "$schema" '\(root.appendingPathComponent("schema.json").path)'
        cp '\(outputFile.path)' "$out"
        """
        try Data(text.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        executable = script
    }
    func mockProposal(_ proposal: AgentShowProposal) throws {
        try mockOutput(String(decoding: JSONEncoder().encode(proposal), as: UTF8.self))
    }
    func configuration(hostPrompt: String = "") -> DJPlanningConfiguration {
        .init(hostPrompt: hostPrompt, executable: executable?.path, environment: ["PATH":"/usr/bin:/bin"], model: nil)
    }
    func seed(_ plan: ProgramPlan) async throws -> ProgramPlan {
        // Explicit private test setup for historical synthetic plans. All
        // transitions after setup still execute through the production daemon.
        _ = try await client.read()
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        let bytes=try encoder.encode(plan)
        let hex=bytes.map { String(format:"%02x",$0) }.joined()
        let idHex=Data(plan.brief.id.utf8).map { String(format:"%02x",$0) }.joined()
        try await sql("INSERT INTO music_dj_owned VALUES(CAST(X'\(idHex)' AS TEXT),CAST(X'\(hex)' AS TEXT)) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload;")
        return plan
    }
    private func sql(_ statement:String) async throws {
        let database=root.appendingPathComponent("tasks.sqlite3").path
        try await Task.detached {
            let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/sqlite3")
            p.arguments=[database,".timeout 5000",statement];p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
            try p.run();p.waitUntilExit();guard p.terminationStatus==0 else {throw PropTaskDaemonError.invalidFrame}
        }.value
    }
    func legacy(plan:ProgramPlan,activeSlotIndex:Int?,updatedAt:Date) async throws {
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        let saved=SavedDJProgram(plan:plan,activeSlotIndex:activeSlotIndex,updatedAt:updatedAt)
        let payload=try JSONDecoder().decode(PropTaskJSON.self,from:encoder.encode(saved))
        _ = try await call("music_import",["source":.string(root.appendingPathComponent(UUID().uuidString+".json").path),"programs":.array([payload]),"playlists":.array([])])
        // Import is intentionally idempotent. Historical archive-update cases
        // explicitly install their final legacy snapshot in this private DB.
        let bytes=try encoder.encode(saved)
        let hex=bytes.map { String(format:"%02x",$0) }.joined()
        let idHex=Data(plan.brief.id.utf8).map { String(format:"%02x",$0) }.joined()
        let date=ISO8601DateFormatter().string(from:updatedAt)
        try await sql("UPDATE music_programs SET updated_at='\(date)',payload=CAST(X'\(hex)' AS TEXT) WHERE id=CAST(X'\(idHex)' AS TEXT);")
    }
    deinit {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: root)
    }
}

struct PrivateDJPlanningAgent: DJPlanningConfigurationProviding {
    let planningConfiguration: DJPlanningConfiguration
    func rankTracks(brief: ProgramBrief, candidates: [MusicCandidate]) async throws -> [String] {
        throw CodexTrackRankingError.invalidResponse // No native model execution.
    }
}
