// Run: swift tools/test-music-session-storage.swift
// Compiles the real session store with its production value types; no app,
// network, keychain, or real user session directory is accessed.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let storeSource = try String(contentsOf: sources.appendingPathComponent("MusicSources/KeychainMusicProviderSessionStore.swift"), encoding: .utf8)
for forbidden in ["import Security", "import LocalAuthentication", "SecItem", "LAContext"] {
    guard !storeSource.contains(forbidden) else {
        print("FAIL: music session storage still calls the system credential service: \(forbidden)")
        exit(1)
    }
}
for file in ["MusicSources/MusicRuntime.swift", "Settings/MusicAccountCommandService.swift"] {
    let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
    guard source.contains("LocalMusicProviderSessionStore()"), !source.contains("KeychainMusicProviderSessionStore()") else {
        print("FAIL: live music services must use local session storage: \(file)")
        exit(1)
    }
}
let modelSource = try String(contentsOf: sources.appendingPathComponent("MusicSources/MusicSource.swift"), encoding: .utf8)
let modelPrefix = modelSource.components(separatedBy: "enum MusicSourceAccess:")[0]
let sessionSource = try String(contentsOf: sources.appendingPathComponent("MusicSources/MusicProviderSession.swift"), encoding: .utf8)
let harness = #"""
@main struct SessionStorageChecks {
    static func check(_ condition: Bool, _ description: String) {
        guard condition else { print("FAIL: \(description)"); exit(1) }
    }
    static func main() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("gmgn-session-test-\(UUID())")
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: root) }
        let directory = root.appendingPathComponent("private-sessions")
        let first = LocalMusicProviderSessionStore(directoryURL: directory)
        check(try await first.session(for: .netease) == nil, "missing session returns nil")
        try await first.removeSession(for: .netease)
        check(!files.fileExists(atPath: directory.path), "missing reads/removals do not create directories")
        let expected = MusicProviderSession(credential: .cookieHeader("MUSIC_U=fake-test-only"), expiresAt: Date(timeIntervalSince1970: 1_900_000_000))
        try await first.save(expected, for: .netease)
        let reopened = LocalMusicProviderSessionStore(directoryURL: directory)
        check(try await reopened.session(for: .netease) == expected, "new store reopens persisted session")
        check(try await reopened.session(for: .qqMusic) == nil, "provider isolation")
        let sessionFile = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first!
        let directoryMode = try files.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try files.attributesOfItem(atPath: sessionFile.path)[.posixPermissions] as? NSNumber
        check(directoryMode?.intValue == 0o700, "private directory is 0700")
        check(fileMode?.intValue == 0o600, "session file is 0600")
        let updated = MusicProviderSession(credential: .bearerToken("fake-replacement"), expiresAt: nil)
        try await reopened.save(updated, for: .netease)
        check(try await first.session(for: .netease) == updated, "separate consumers see replacement without stale cache")
        check(try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 1, "atomic replacement leaves only one committed file")
        try await reopened.save(expected, for: .qqMusic)
        try await reopened.removeSession(for: .netease)
        check(try await first.session(for: .netease) == nil, "disconnect deletes persisted session for all consumers")
        check(try await first.session(for: .qqMusic) == expected, "disconnect preserves another provider")
        try await first.removeSession(for: .netease)
        let corruptFile = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first!
        try Data("invalid-test-data".utf8).write(to: corruptFile)
        do {
            _ = try await first.session(for: .qqMusic)
            check(false, "corrupt data must report an error")
        } catch MusicProviderSessionStoreError.invalidStoredSession {}
        check(files.fileExists(atPath: corruptFile.path), "corrupt data is not silently deleted")
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let failing = LocalMusicProviderSessionStore(directoryURL: blocked)
        do {
            try await failing.save(expected, for: .netease)
            check(false, "write errors must propagate")
        } catch {}
        do {
            _ = try await failing.session(for: .netease)
            check(false, "read errors must propagate")
        } catch {}
        let unusual: MusicProviderID = "../../other/provider"
        try await first.save(updated, for: unusual)
        check(try await first.session(for: unusual) == updated, "provider identifiers cannot escape the private directory")
        check(try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count == 2, "only injected private directory and test sentinel exist")
        print("PASS: local session persistence, reopening, replacement, deletion, provider isolation, permissions, missing/corrupt data, I/O errors, and live wiring; no keychain calls")
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-session-harness-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: temporary) }
let swiftFile = temporary.appendingPathComponent("SessionChecks.swift")
let executable = temporary.appendingPathComponent("checks")
try [modelPrefix, sessionSource, storeSource, harness].joined(separator: "\n").write(to: swiftFile, atomically: true, encoding: .utf8)
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = ["-parse-as-library", swiftFile.path, "-o", executable.path]
try compiler.run()
compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let checks = Process()
checks.executableURL = executable
try checks.run()
checks.waitUntilExit()
exit(checks.terminationStatus)
