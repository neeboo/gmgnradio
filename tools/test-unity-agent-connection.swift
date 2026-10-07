import Foundation

@MainActor private final class TestCodexAccount: CodexAccountServicing {
    var statusCalls = 0, loginCalls = 0, logoutCalls = 0
    var state: CodexAccountState = .signedOut
    func status() async -> CodexAccountState { statusCalls += 1; return state }
    func login() async throws { loginCalls += 1; state = .signedIn(method: "Test") }
    func logout() async throws { logoutCalls += 1; state = .signedOut }
}

@main struct UnityAgentConnectionTests {
    @MainActor static func main() async {
        let account = TestCodexAccount()
        var selected = "dsh"
        var installed: Set<String> = ["dsh"]
        let bridge = UnityAgentConnectionBridge(account: account,
            backends: { [["id": "dsh", "name": "DSH", "installed": true], ["id": "codex", "name": "Codex", "installed": false]] },
            currentBackend: { selected }, selectBackend: {
                guard installed.contains($0) else { return false }
                selected = $0; return true
            })
        precondition(account.statusCalls == 0 && account.loginCalls == 0 && account.logoutCalls == 0)
        bridge.refresh()
        while bridge.snapshot["working"] as? Bool == true { await Task.yield() }
        precondition(account.statusCalls == 1 && account.loginCalls == 0 && account.logoutCalls == 0)
        precondition(bridge.command(["op": "agent.login"]))
        while bridge.snapshot["working"] as? Bool == true { await Task.yield() }
        precondition(account.loginCalls == 1 && bridge.snapshot["codexState"] as? String == "signedIn")
        precondition(!bridge.command(["op": "agent.backend", "id": "codex"]))
        precondition(selected == "dsh")
        installed.insert("codex")
        // Explicit selection's fresh consumer owns installation validation;
        // the old rendered list must not reject a newly installed backend.
        precondition(bridge.command(["op": "agent.backend", "id": "codex"]))
        precondition(selected == "codex")
        precondition(!bridge.command(["op": "agent.backend", "id": "unknown"]))
        precondition(bridge.command(["op": "agent.save", "backendID": "dsh"]))
        precondition(!bridge.command(["op": "agent.save", "residentPersona": "must remain owned by product settings"]))
        precondition(account.logoutCalls == 0)
        print("Unity Agent explicit authentication and actual backend consumer: passed")
    }
}
