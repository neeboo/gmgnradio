import Foundation

@MainActor private final class TestCodexAccount: CodexAccountServicing {
    var statusCalls = 0, loginCalls = 0, logoutCalls = 0
    var state: CodexAccountState = .signedOut
    func status() async -> CodexAccountState { statusCalls += 1; return state }
    func login() async throws { loginCalls += 1; state = .signedIn(method: "Test") }
    func logout() async throws { logoutCalls += 1; state = .signedOut }
}

@main struct UnityAgentConnectionTests {
    static func check(_ result: Bool) { precondition(result) }
    @MainActor static func main() async {
        let account = TestCodexAccount()
        var selected = "dsh"
        let gate = SelectionReceiptGate()
        var confirmedChanges = 0
        let bridge = UnityAgentConnectionBridge(account: account,
            backends: { [["id": "dsh", "name": "DSH", "installed": true], ["id": "codex", "name": "Codex", "installed": false]] },
            currentBackend: { selected }, selectBackend: {
                guard gate.installed.contains($0) else { return false }
                guard selected != $0 else { return true }
                guard await gate.result() else { return false }
                selected = $0; confirmedChanges += 1; return true
            })
        precondition(account.statusCalls == 0 && account.loginCalls == 0 && account.logoutCalls == 0)
        bridge.refresh()
        while bridge.snapshot["working"] as? Bool == true { await Task.yield() }
        precondition(account.statusCalls == 1 && account.loginCalls == 0 && account.logoutCalls == 0)
        check(await bridge.command(["op": "agent.login"]))
        while bridge.snapshot["working"] as? Bool == true { await Task.yield() }
        precondition(account.loginCalls == 1 && bridge.snapshot["codexState"] as? String == "signedIn")
        check(!(await bridge.command(["op": "agent.backend", "id": "codex"])))
        precondition(selected == "dsh")
        gate.installed.insert("codex")
        // Explicit selection's fresh consumer owns installation validation;
        // the old rendered list must not reject a newly installed backend.
        gate.deferReceipt = true
        var completed = false
        let selecting = Task { @MainActor in
            let result = await bridge.command(["op": "agent.backend", "id": "codex"])
            completed = true; return result
        }
        while gate.pending == nil { await Task.yield() }
        precondition(!completed && selected == "dsh" && confirmedChanges == 0)
        gate.resolve(true)
        check(await selecting.value)
        precondition(selected == "codex")
        let changes = confirmedChanges, requests = gate.requests
        check(await bridge.command(["op": "agent.backend", "id": "codex"]))
        precondition(confirmedChanges == changes && gate.requests == requests) // No same-value cancellation or write.
        check(!(await bridge.command(["op": "agent.backend", "id": "unknown"])))
        let rejected = Task { @MainActor in await bridge.command(["op":"agent.backend", "id":"dsh"]) }
        while gate.pending == nil { await Task.yield() }
        precondition(selected == "codex")
        gate.resolve(false)
        check(!(await rejected.value))
        precondition(selected == "codex" && confirmedChanges == changes)
        gate.deferReceipt = false
        check(await bridge.command(["op": "agent.save", "backendID": "dsh"]))
        check(!(await bridge.command(["op": "agent.save", "residentPersona": "must remain owned by product settings"])))
        precondition(account.logoutCalls == 0)
        print("Unity Agent explicit authentication and actual backend consumer: passed")
    }
}

@MainActor private final class SelectionReceiptGate {
    var installed: Set<String> = ["dsh"]
    var deferReceipt = false, requests = 0
    var pending: CheckedContinuation<Bool, Never>?
    func result() async -> Bool {
        requests += 1
        if !deferReceipt { return true }
        return await withCheckedContinuation { pending = $0 }
    }
    func resolve(_ value: Bool) { let receipt = pending; pending = nil; receipt?.resume(returning: value) }
}
