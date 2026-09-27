import Foundation

enum ResidentCodexPolicyError: Error, LocalizedError {
    case invalidConfiguration
    case unsafeConfiguration

    var errorDescription: String? {
        "居民连接的工具权限未能确认，请检查 Codex 版本与配置。"
    }
}

enum ResidentCodexPolicy {
    private static let disabledFeatures = [
        "plugins", "apps", "hooks", "multi_agent", "multi_agent_v2",
        "image_generation", "shell_tool",
    ]

    /// The complete config response must stay inside this boundary. Do not log it.
    private static func configuration(_ response: Data) throws -> [String: Any] {
        guard let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let config = envelope["config"] as? [String: Any] else {
            throw ResidentCodexPolicyError.invalidConfiguration
        }
        return config
    }

    static func serverNames(in response: Data) throws -> [String] {
        let config = try configuration(response)
        guard let raw = config["mcp_servers"] else { return [] }
        guard let servers = raw as? [String: Any] else {
            throw ResidentCodexPolicyError.invalidConfiguration
        }
        return servers.keys.sorted()
    }

    /// Resident Codex keeps its hosted web_search capability: it is a
    /// server-side tool that reads public pages and never depends on the local
    /// sandbox, so it does not weaken the read-only workspace boundary below.
    /// `live` is the open mode (per Codex docs, `"disabled"` turns the tool
    /// off; `"cached"`/`"indexed"` gate to an index). Results stay untrusted
    /// model input like any other fetched content.
    static let residentWebSearchMode = "live"

    static func arguments(disabling names: [String]) throws -> [String] {
        var overrides = disabledFeatures.map { "features.\($0)=false" }
        overrides += ["agents.enabled=false", "notify=[]", "web_search=\"\(residentWebSearchMode)\"",
                      "cli_auth_credentials_store=\"file\"", "mcp_oauth_credentials_store=\"file\""]
        if !names.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let fields = try Set(names).sorted().map {
                String(decoding: try encoder.encode($0), as: UTF8.self) + "={enabled=false}"
            }
            // Codex splits dotted override paths itself. Literal names belong in
            // this inline table, not in mcp_servers.<name>.enabled paths.
            overrides.append("mcp_servers={" + fields.joined(separator: ",") + "}")
        }
        return ["app-server", "--stdio"] + overrides.flatMap { ["-c", $0] }
    }

    static func verify(_ response: Data) throws {
        let config = try configuration(response)
        guard let features = config["features"] as? [String: Any],
              disabledFeatures.allSatisfy({ features[$0] as? Bool == false }),
              let agents = config["agents"] as? [String: Any], agents["enabled"] as? Bool == false,
              let notify = config["notify"] as? [Any], notify.isEmpty,
              let webSearch = config["web_search"] as? String, !webSearch.isEmpty,
              webSearch != "disabled",
              config["cli_auth_credentials_store"] as? String == "file",
              config["mcp_oauth_credentials_store"] as? String == "file" else {
            throw ResidentCodexPolicyError.unsafeConfiguration
        }
        for name in try serverNames(in: response) {
            guard let servers = config["mcp_servers"] as? [String: Any],
                  let server = servers[name] as? [String: Any],
                  server["enabled"] as? Bool == false else {
                throw ResidentCodexPolicyError.unsafeConfiguration
            }
        }
    }

    static func environment(from source: [String: String]) -> [String: String] {
        let allowed: Set<String> = [
            "HOME", "CODEX_HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "SHELL",
            "LANG", "LC_ALL", "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY",
            "https_proxy", "http_proxy", "all_proxy", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR",
        ]
        var result = source.filter { allowed.contains($0.key) }
        // Finder-launched apps often omit Homebrew. npm's Codex launcher uses
        // /usr/bin/env node, so locating the launcher alone is insufficient.
        let standardDirectories = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let inheritedDirectories = (source["PATH"] ?? "").split(separator: ":").map(String.init)
        result["PATH"] = (standardDirectories + inheritedDirectories)
            .reduce(into: [String]()) { paths, directory in
                if !paths.contains(directory) { paths.append(directory) }
            }
            .joined(separator: ":")
        result["CODEX_EXEC_SERVER_URL"] = "none"
        return result
    }
}
