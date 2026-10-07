import Foundation

/// Reads the original Codex identity; authentication only runs after an
/// explicit settings command. Backend selection must be consumed by Host.
@MainActor
final class UnityAgentConnectionBridge {
    private let account: any CodexAccountServicing
    private let backends: () -> [[String: Any]]
    private let currentBackend: () -> String
    private let selectBackend: (String) -> Bool
    private var task: Task<Void, Never>?
    private var state: CodexAccountState = .unavailable
    private var notice: String?
    private var hasError = false

    static let supportedCommands = ["agent.status", "agent.login", "agent.logout", "agent.backend"]

    init(account: any CodexAccountServicing = CodexAgentAccountService(),
         backends: @escaping () -> [[String: Any]], currentBackend: @escaping () -> String,
         selectBackend: @escaping (String) -> Bool) {
        self.account = account; self.backends = backends
        self.currentBackend = currentBackend; self.selectBackend = selectBackend
    }

    func refresh() { _ = command(["op": "agent.status"]) }
    func stop() { task?.cancel(); task = nil }

    var snapshot: [String: Any] {
        let status: String
        let raw: String
        switch state {
        case .unavailable: raw = "unavailable"; status = "Codex CLI 不可用"
        case .signedOut: raw = "signedOut"; status = "Codex 未登录"
        case .signedIn(let method): raw = "signedIn"; status = "Codex · \(method)"
        }
        return ["codexState": raw, "codexStatus": status, "working": task != nil,
                "backendID": currentBackend(), "backends": backends(),
                "backendStatus": backends().first(where: { $0["id"] as? String == currentBackend() })?["name"] as? String ?? currentBackend(),
                "notice": notice as Any? ?? NSNull(), "hasError": hasError]
    }

    func command(_ value: [String: Any]) -> Bool {
        guard let op = value["op"] as? String else { return false }
        if op == "agent.backend" || (op == "agent.save" && value["backendID"] != nil) {
            guard let id = (value["backendID"] ?? value["id"]) as? String,
                  selectBackend(id), currentBackend() == id else { return false }
            return true
        }
        guard ["agent.status", "agent.login", "agent.logout"].contains(op), task == nil else { return false }
        hasError = false; notice = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if op == "agent.login" { try await account.login() }
                if op == "agent.logout" { try await account.logout() }
                guard !Task.isCancelled else { return }
                state = await account.status()
            } catch {
                guard !Task.isCancelled else { return }
                hasError = true; notice = "账号操作失败，请检查 Codex CLI 后重试。"
            }
            task = nil
        }
        return true
    }
}
