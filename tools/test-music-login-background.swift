// Production login service regression; isolated fake sessions, no App or network.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
func read(_ path: String) throws -> String {
    try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
}
let account = try read("MusicSources/AccountMusicSource.swift")
let accountTypes = String(account[..<account.range(of: "enum MusicSourceError:")!.lowerBound])
let sourceTypes = try read("MusicSources/MusicSource.swift")
let harness = #"""
import Foundation
enum ProbeError: Error { case rejected }
actor ProbeClient: AccountMusicProviderClient {
    private func isOnMainThread() -> Bool { Thread.isMainThread }
    var validations = 0
    var libraries = 0
    var onMain = false
    let reject: Bool
    init(reject: Bool = false) { self.reject = reject }
    func capabilities(session: MusicProviderSession) async throws -> MusicAccountCapabilities {
        MusicAccountCapabilities(canSearchCatalog: true, canReadLibrary: true, canReadPlaylists: true, canReadRecentPlays: false, canPlay: true)
    }
    func validateAccount(session: MusicProviderSession) async throws {
        validations += 1; onMain = isOnMainThread()
        if reject { throw ProbeError.rejected }
    }
    func fetchUserLibrary(session: MusicProviderSession) async throws -> MusicProviderLibrary {
        libraries += 1; throw ProbeError.rejected
    }
    func search(_ request: MusicSearchRequest, session: MusicProviderSession) async throws -> [MusicProviderTrack] { [] }
}
typealias QQMusicProviderClient = ProbeClient
actor LoginTransport: MusicProviderHTTPTransport {
    var paths: [String] = []
    func send(_ request: URLRequest) async throws -> MusicProviderHTTPResponse {
        paths.append(request.url!.path)
        return MusicProviderHTTPResponse(data: Data("{\"code\":200,\"profile\":{\"userId\":12345}}".utf8), statusCode: 200)
    }
}
@main struct Checks {
    @MainActor static func main() async throws {
        let client = ProbeClient()
        let store = InMemoryMusicProviderSessionStore()
        let service = MusicAccountCommandService(sessions: store, neteaseClient: client, qqMusicClient: client)
        try await service.connect(providerID: .netease, cookie: "MUSIC_U=isolated-test")
        guard await client.validations == 1, await client.libraries == 0,
              await client.onMain == false, await store.session(for: .netease) != nil else { fatalError("login lifecycle regression") }
        let rejected = ProbeClient(reject: true)
        let empty = InMemoryMusicProviderSessionStore()
        let failing = MusicAccountCommandService(sessions: empty, neteaseClient: rejected, qqMusicClient: rejected)
        do { try await failing.connect(providerID: .netease, cookie: "MUSIC_U=isolated-test"); fatalError("rejected validation saved") }
        catch ProbeError.rejected {}
        guard await empty.session(for: .netease) == nil, await rejected.libraries == 0 else { fatalError("failed login persisted") }
        let transport = LoginTransport()
        let actual = NeteaseMusicProviderClient(transport: transport)
        try await actual.validateAccount(session: MusicProviderSession(credential: .cookieHeader("MUSIC_U=isolated-test"), expiresAt: nil))
        guard await transport.paths == ["/weapi/w/nuser/account/get"] else { fatalError("login requested complete library") }
        print("PASS: login validates off-main once, no full library fetch, validation failure is not saved")
        print("PASS: real Netease client requests only account status during validation")
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-login-background-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: temporary) }
let combined = temporary.appendingPathComponent("Checks.swift")
try (sourceTypes + "\n" + accountTypes + "\n" + harness).write(to: combined, atomically: true, encoding: .utf8)
let binary = temporary.appendingPathComponent("checks")
func run(_ command: String, _ arguments: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: command); process.arguments = arguments
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
let inputs = ["Settings/MusicAccountCommandService.swift", "MusicSources/MusicProviderSession.swift", "MusicSources/KeychainMusicProviderSessionStore.swift", "MusicSources/MusicProviderHTTPTransport.swift", "MusicSources/NeteaseMusicProviderClient.swift"].map { sources.appendingPathComponent($0).path }
let compiled = try run("/usr/bin/swiftc", ["-swift-version", "6", "-j1", "-parse-as-library"] + inputs + [combined.path, "-o", binary.path])
guard compiled == 0 else { exit(compiled) }
exit(try run(binary.path, []))
