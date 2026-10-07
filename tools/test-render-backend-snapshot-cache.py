#!/usr/bin/env python3
"""Compile actual hot-path getter and cache, with a counted install probe."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
bridge = (repo / "apps/macos/RenderHost/ResidentConversationBridge.swift").read_text()
service = (repo / "apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift").read_text()
getter = bridge.split("    var installedBackendSnapshot:", 1)[1].split("    @discardableResult", 1)[0]
cache = service.split("    private var installedBackendCache:", 1)[1].split("    /// 是否至少", 1)[0]
program = '''import Foundation
enum BackendKind: String { case codex, dsh, other }
struct AgentConversationBackend { let kind: BackendKind; let displayName: String }
enum AgentConversationBackends {
    static let all = [AgentConversationBackend(kind: .codex, displayName: "Codex"),
        AgentConversationBackend(kind: .dsh, displayName: "DSH"),
        AgentConversationBackend(kind: .other, displayName: "Other")]
}
final class Service {
    var probes = 0
    var available: Set<BackendKind> = [.codex, .dsh, .other]
    func isInstalled(_ id: BackendKind) -> Bool { probes += 1; return available.contains(id) }
    private var installedBackendCache:''' + cache + '''
    func expireForTest() { installedBackendCache?.checkedAt = Date(timeIntervalSinceNow: -60) }
}
final class Bridge {
    let service = Service()
    var backend = "codex"
    var installedBackendSnapshot:''' + getter + '''
}
let bridge = Bridge()
precondition(bridge.installedBackendSnapshot.isEmpty)
precondition(bridge.service.probes == 0, "Cold render snapshot performed discovery")
bridge.refreshInstalledBackends()
for _ in 0..<10000 {
    bridge.service.expireForTest()
    let snapshot = bridge.installedBackendSnapshot
    precondition(snapshot.count == 2)
    precondition(snapshot.first?["selected"] as? Bool == true)
}
precondition(bridge.service.probes == 3, "Render snapshot rescanned installation")
bridge.service.expireForTest()
_ = bridge.installedBackendSnapshot
precondition(bridge.service.probes == 3, "Expired render snapshot performed discovery")
_ = bridge.service.installedBackends()
precondition(bridge.service.probes == 6, "Ordinary service TTL stopped refreshing")
_ = bridge.service.installedBackends(refresh: true)
precondition(bridge.service.probes == 9, "Explicit install refresh was lost")
bridge.service.available = []
bridge.service.expireForTest()
bridge.refreshInstalledBackends()
precondition(bridge.installedBackendSnapshot.isEmpty, "Removal must expire to empty")
bridge.service.available = [.dsh]
precondition(bridge.installedBackendSnapshot.isEmpty, "Empty result must also be cached")
bridge.service.expireForTest()
precondition(bridge.installedBackendSnapshot.isEmpty, "Expired empty render snapshot performed discovery")
bridge.refreshInstalledBackends()
precondition(bridge.installedBackendSnapshot.first?["id"] as? String == "dsh", "New install must appear after expiry")
bridge.service.available = [.codex]
_ = bridge.service.installedBackends(refresh: true)
precondition(bridge.installedBackendSnapshot.first?["id"] as? String == "codex", "Explicit change must invalidate cached install list")
print("PASS: 10000 actual render snapshots beyond 60s TTL scan once; explicit refresh/removal/new install and ordinary TTL preserved")
'''
with tempfile.TemporaryDirectory(prefix="gmgn-backend-cache-") as temporary:
    directory = Path(temporary)
    swift = directory / "main.swift"
    swift.write_text(program)
    executable = directory / "cache-check"
    subprocess.run(["swiftc", str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
