#!/usr/bin/env python3
"""Run production connection bridge without invoking live authentication."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
account = (repo / "apps/macos/Sources/GMGNRadio/Agent/CodexAgentAccountService.swift").read_text()
protocol = account.split("@MainActor\nfinal class CodexAgentAccountService", 1)[0]
stub = '''@MainActor final class CodexAgentAccountService: CodexAccountServicing {
    nonisolated init() {}
    func status() async -> CodexAccountState { .unavailable }
    func login() async throws { fatalError("Live login forbidden in test") }
    func logout() async throws { fatalError("Live logout forbidden in test") }
}
'''
with tempfile.TemporaryDirectory(prefix="gmgn-agent-selection-") as temporary:
    directory = Path(temporary)
    definitions = directory / "Account.swift"
    definitions.write_text(protocol + stub)
    executable = directory / "connection-check"
    subprocess.run(["swiftc", "-parse-as-library", str(definitions),
        str(repo / "apps/macos/UnityHost/UnityAgentConnectionBridge.swift"),
        str(repo / "tools/test-unity-agent-connection.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
