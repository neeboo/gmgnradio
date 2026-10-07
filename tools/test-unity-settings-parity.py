#!/usr/bin/env python3
"""Execute production settings slices against isolated defaults, without UI/authority."""
from pathlib import Path
import re
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
product = (repo / "apps/macos/UnityHost/UnityProductSettings.swift").read_text()
host = (repo / "apps/macos/UnityHost/UnityMediaHost.swift").read_text()
bridge = (repo / "apps/macos/UnityHost/UnityResidentAgentLoopBridge.swift").read_text()
preferences = (repo / "apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift").read_text()
preferences = "@MainActor\nstruct ResidentPreferences {" + preferences.split("struct ResidentPreferences {", 1)[1].split("// MARK: - Outcome", 1)[0]
save = product.split('        case "agent.save":', 1)[1].split('        case "agent.backend"', 1)[0]
host_save = host.split('        case "agent.save":', 1)[1].split('        case _ where UnityShortcut', 1)[0]
pause = bridge.split('    func pauseByUser() {', 1)[1].split('    func receive(', 1)[0]
enabled_key = bridge.split('    static let enabledKey = ', 1)[1].split('\n', 1)[0]
library_route = re.search(r'case "space\.library\.load", "space\.library\.select"(?:, "space\.default")?:([^\n]+)', host).group(1)
ops = host.split('"supportedCommands": [', 1)[1].split(']\n', 1)[0]
groups = host.split('"availableAgentGroups": [', 1)[1].split(']', 1)[0]
assert all(f'"{name}"' in groups for name in ["回复语音", "按住说话", "居民人格", "角色内核", "聊天模型", "自主行动", "角色人格与偏好"])
assert '"planningSupported": true' in host
assert 'musicPlanningAvailable: true' in host and 'program: djProgram' in host
assert 'self?.djPreferences.takeoverEnabled() ?? false' in host
assert 'defer { residentAutonomy?.refresh() }' in host
assert '"autonomyEnabled": defaults.object(forKey: UnityResidentAgentLoopBridge.enabledKey) as? Bool ?? true' in product
assert '"backgroundTurnsPerHour": resident.backgroundTurnsPerHour' in product
assert '"budgetOptions": Array(0...ResidentPreferences.maximumBackgroundTurnsPerHour)' in product
transport = (repo / "apps/gpui-app/src/unity_settings_transport.rs").read_text()
assert 'ops.iter().any(|op| op == &command["op"])' in transport

program = 'import Foundation\n' + preferences + '''
@MainActor final class Loop {
    var stopped = false
    func stop() { stopped = true }
    func resumeAutonomyByUser() -> Bool { stopped = false; return true }
}
@MainActor final class UnityResidentAgentLoopBridge {
    static let enabledKey = ''' + enabled_key + '''
    let defaults: UserDefaults
    let loop = Loop()
    var closed = false, refreshes = 0
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func refresh() { refreshes += 1 }
    func pauseByUser() {''' + pause + '''}
@MainActor final class Product {
    let defaults: UserDefaults
    static let autoSpeakKey = "unity.agent.autoSpeakReplies"
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func stopReplySpeech() {}
    func command(_ value: [String: Any]) -> Bool {
        guard let op = value["op"] as? String else { return false }
        switch op { case "agent.save":''' + save + '''
        default: return false }
        return true
    }
}
@MainActor final class Connection { func command(_ value: [String: Any]) -> Bool { true } }
@MainActor final class Library {
    var loaded = false, selected = "original"
    func settingsCommand(_ value: [String: Any]) -> Bool {
        if value["op"] as? String == "space.library.load" { loaded = true; return true }
        guard let id = value["id"] as? String else { return false }
        selected = id; return true
    }
}
@MainActor final class Host {
    let productSettings: Product
    let agentConnection = Connection(), spaceLibrary = Library()
    var residentAutonomy: UnityResidentAgentLoopBridge?
    init(_ defaults: UserDefaults) { productSettings = Product(defaults); residentAutonomy = UnityResidentAgentLoopBridge(defaults) }
    func command(_ value: [String: Any]) -> Bool {
        guard let op = value["op"] as? String else { return false }
        defer { residentAutonomy?.refresh() }
        switch op {
        case "space.library.load", "space.library.select":''' + library_route + '''
        case "agent.save":''' + host_save + '''
        default: return false }
    }
}
@main struct Test {
    @MainActor static func main() {
        let suite = "gmgn-settings-parity-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = Host(defaults), resident = ResidentPreferences(defaults: defaults)
        precondition(resident.backgroundTurnsPerHour == 6)
        precondition(host.command(["op": "agent.save", "autonomyEnabled": false]))
        precondition(defaults.bool(forKey: UnityResidentAgentLoopBridge.enabledKey) == false)
        precondition(host.residentAutonomy!.loop.stopped)
        precondition(host.command(["op": "agent.save", "autonomyEnabled": true, "backgroundTurnsPerHour": 2]))
        precondition(defaults.bool(forKey: UnityResidentAgentLoopBridge.enabledKey))
        precondition(!host.residentAutonomy!.loop.stopped && resident.backgroundTurnsPerHour == 2)
        precondition(host.residentAutonomy!.refreshes >= 4)
        precondition(host.command(["op": "agent.save", "backgroundTurnsPerHour": 99]))
        precondition(resident.backgroundTurnsPerHour == 6)
        precondition(host.command(["op": "agent.save", "backgroundTurnsPerHour": -3]))
        precondition(resident.backgroundTurnsPerHour == 0)
        precondition(host.command(["op": "agent.save", "residentPersona": "new persona", "autoSpeak": false]))
        precondition(resident.persona == "new persona" && resident.backgroundTurnsPerHour == 0)
        precondition(!host.command(["op": "agent.save", "autonomyEnabled": false, "backgroundTurnsPerHour": "bad"]))
        precondition(defaults.bool(forKey: UnityResidentAgentLoopBridge.enabledKey))
        precondition(!host.command(["op": "agent.save", "hostPrompt": "unsupported"]))
        let supportedCommands: [String] = [''' + ops + ''']
        for command: [String: Any] in [["op": "space.library.load"], ["op": "space.library.select", "id": "new-space"]] {
            precondition(supportedCommands.contains(command["op"] as! String))
            precondition(host.command(command))
        }
        precondition(host.spaceLibrary.loaded && host.spaceLibrary.selected == "new-space")
        print("PASS persisted autonomy pause/resume, production budget clamping, sibling settings preservation, invalid payload rejection, exported whitelist to actual space-library route; device-free slices, no UI or authority acceptance")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="gmgn-settings-parity-") as directory:
    source = Path(directory) / "test.swift"
    source.write_text(program)
    executable = Path(directory) / "test"
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
