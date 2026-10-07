#!/usr/bin/env python3
"""Real configuration persistence + production consumer, synthetic credentials only."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
configuration = (root/'apps/macos/Sources/GMGNRadio/Presence/PropGenerationConfiguration.swift').read_text()
bridge = (root/'apps/macos/UnityHost/UnityGenerationConfigurationBridge.swift').read_text()
stub = r'''
import Foundation
enum PropGenerationError: Error { case invalidEndpoint, missingToken }
struct PropGenerationClient {
    let endpoint: URL
    init(endpoint: URL, token: String) throws {
        guard ["http","https"].contains(endpoint.scheme), endpoint.host != nil else { throw PropGenerationError.invalidEndpoint }
        guard !token.isEmpty else { throw PropGenerationError.missingToken }; self.endpoint = endpoint
    }
    func health() async throws -> Bool { true }
}
@MainActor final class PropGenerationStore {
    var errorMessage: String?
    var calls = 0
    var endpoint: URL?
    func configure(endpoint: URL, token: String) throws { calls += 1; self.endpoint = endpoint }
    func clearConfiguration() { endpoint = nil }
}
'''
harness = r'''
@main struct Tests {
    @MainActor static func main() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent("old/secrets.json")
        let currentURL = dir.appendingPathComponent("new/secrets.json")
        let old = PropGenerationConfigurationStore(fileURL:legacyURL)
        try old.save(try PropGenerationConfiguration(endpoint:URL(string:"http://127.0.0.1:8191")!,token:"synthetic-test-token"))
        let store = PropGenerationStore()
        let b = UnityGenerationConfigurationBridge(store:store,fileURL:currentURL,readableLegacyFileURL:legacyURL)
        assert(store.calls == 1 && store.endpoint != nil)
        assert(!FileManager.default.fileExists(atPath:currentURL.path))
        assert(b.snapshot["token"] == nil)
        assert(b.settingsCommand(["op":"generation.save","endpoint":"http://127.0.0.1:8192"]))
        assert(store.calls == 1 && b.snapshot["hasError"] as? Bool == true)
        assert(b.settingsCommand(["op":"generation.save","endpoint":"http://127.0.0.1:8191"]))
        assert(store.calls == 2 && FileManager.default.fileExists(atPath:currentURL.path))
        let saved = try PropGenerationConfigurationStore(fileURL:currentURL).load()!
        let original = try old.load(); assert(saved == original)
        assert(b.settingsCommand(["op":"generation.save","endpoint":"http://127.0.0.1:8192","token":"synthetic-new-token"]))
        assert(store.calls == 3 && store.endpoint!.port == 8192)
        b.close(); assert(!b.settingsCommand(["op":"generation.load"]))
        try Data("bad-json".utf8).write(to:currentURL)
        let failed = UnityGenerationConfigurationBridge(store:store,fileURL:currentURL,readableLegacyFileURL:legacyURL)
        assert(failed.snapshot["configured"] as? Bool == false && store.endpoint == nil)
        let corrupt = try Data(contentsOf:currentURL); assert(corrupt == Data("bad-json".utf8))
        print("PASS: generation consumer load/save, no implicit credential copy, endpoint/key binding, corrupt current rejects legacy, close")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='gmgn-generation-config-test-') as tmp:
    source = Path(tmp)/'Tests.swift'
    source.write_text(stub+configuration+bridge+harness)
    binary = Path(tmp)/'test'
    subprocess.run(['swiftc','-parse-as-library',str(source),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
