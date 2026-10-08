#!/usr/bin/env python3
"""Compile the actual production adapter methods with minimal UI-free stubs."""
import importlib.util
import pathlib
import subprocess
import tempfile
import threading
import http.server
import shutil

ROOT = pathlib.Path(__file__).resolve().parents[3]
SOURCE = ROOT / 'apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift'

def declaration(source, marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        # Adapter has no braces in string literals; balanced scan keeps exact body.
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

fixture_path = pathlib.Path(__file__).with_name('rust_codex_swift_client.py')
# Import only the reusable fixture class, not its executable test block.
fixture_source = fixture_path.read_text().split('with tempfile.TemporaryDirectory')[0]
namespace = {'__file__': str(fixture_path)}
exec(fixture_source, namespace)
BaseFixture = namespace['Fixture']

class Fixture(BaseFixture):
    def do_POST(self):
        # Production adapter owns its random private cwd and sends prompt-only input.
        # The base fixture expects more inputs, so preserve its other checks while
        # replacing only the start and image receipt schema assertions here.
        import json
        if self.path.endswith('agent_cli_read') and self.server.phase == 'hostunknown':
            self.rfile.read(int(self.headers['Content-Length']))
            self.server.calls.append('agent_cli_read')
            data = json.dumps({'state':'unknown','text':'hello','pendingTools':[], 'threadID':'thread','turnID':'turn'}).encode()
            self.send_response(200); self.end_headers(); self.wfile.write(data)
            return
        if self.path.endswith('agent_cli_start') or self.path.endswith('agent_cli_tool_receipt'):
            p = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            method = self.path.rsplit('/', 1)[-1]; self.server.calls.append(method)
            if method == 'agent_cli_start':
                assert p['input'] == [{'type': 'text', 'text': 'test', 'text_elements': []}]
                assert p['root'] == p['cwd'] and pathlib.Path(p['cwd']).is_dir()
                assert pathlib.Path(p['cwd']) == pathlib.Path(p['cwd']).resolve(), 'production cwd must be canonical, without /var symlink aliases'
                assert p['resumeThreadID'] == 'thread' and p['tools'][0]['effect'] == 'write'
                self.server.private_paths.append(pathlib.Path(p['cwd']))
            else:
                assert p['threadID'] == 'thread' and p['turnID'] == 'turn' and p['operationID'] == 'business-op'
                if self.server.scenario.startswith('hostunknown'):
                    assert p['status']=='unknown' and p['output']=={'ok':False,'code':'world_prop_execution_unknown'}
                    assert 'images' not in p
                    self.server.phase='hostunknown'
                elif self.server.scenario=='rejected':
                    assert p['status']=='rejected' and p['output']=={'ok':False,'code':'world_prop_invalid_support'}
                    self.server.phase='done'
                else:
                    assert p['status']=='completed' and p['output'] == {'ok': True} and p['images'][0]['mediaType'] == 'image/png'
                    assert p['images'][0]['base64'].startswith('iVBORw0KGgo')
                    self.server.phase = 'done'
            data = json.dumps({'accepted': True}).encode()
            self.send_response(200); self.end_headers(); self.wfile.write(data)
        else:
            super().do_POST()

source = SOURCE.read_text()
bindings = '\n'.join(declaration(source, marker) for marker in ('struct RustResidentToolBinding:', 'struct RustResidentDSHToolBinding:', 'struct RustResidentClaudeToolBinding:', 'struct ResidentConversationTools:'))
methods = declaration(source, '    private func sendRustResident(') + '\n' + declaration(source, '    private func recordRustResidentFailure(') + '\n' + declaration(source, '    nonisolated static func rustHostReceiptStatus(')
transport = pathlib.Path(__file__).with_name('rust_codex_swift_client.swift').read_text().split('actor CLISink')[0]
stubs = '''
struct ResidentVisionImage: Sendable { let pngData: Data }
struct ResidentCodexToolReply: Sendable { let resultJSON: Data; let isError: Bool; var image: ResidentVisionImage? }
struct AgentConversationOutcome { let reply: String; let sessionID: String }
enum AgentConversationError: Error { case worldToolsUnavailable }
enum ResidentCodexAgentError: Error { case turnFailed }
@MainActor final class AgentConversationService {
    var currentRustResidentClient: RustCodexSessionClient?
    var lastResidentFailure: [String: Any] = [:]
    var residentFailureHistory: [[String: Any]] = []
    static let residentFailureHistoryLimit = 8
    func testSend(executable: URL, prompt: String, imageURLs: [URL], sessionID: String?, tools: ResidentConversationTools) async throws -> AgentConversationOutcome {
        try await sendRustResident(executable: executable, prompt: prompt, imageURLs: imageURLs, sessionID: sessionID, tools: tools)
    }
'''
with tempfile.TemporaryDirectory(prefix='gmgn-cli-adapter-') as directory:
    generated = pathlib.Path(directory) / 'adapter.swift'
    generated.write_text(transport + '\n' + bindings + '\n' + stubs + '\n' + methods + '\n}\n')
    binary = pathlib.Path(directory) / 'test'
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(generated),
                    str(ROOT / 'apps/macos/Sources/GMGNRadio/Presence/RustCodexSessionClient.swift'),
                    str(ROOT / 'apps/macos/Sources/GMGNRadio/Presence/RustDSHSessionClient.swift'),
                    str(ROOT / 'apps/macos/Sources/GMGNRadio/Presence/RustResidentClaudeClient.swift'),
                    str(ROOT / 'apps/macos/Sources/GMGNRadio/Agent/ResidentCodexPolicy.swift'),
                    str(pathlib.Path(__file__).with_suffix('.swift')), '-o', str(binary)], check=True)
    for scenario in ('adapter', 'bindingmissing', 'hostunknown', 'hostunknownbadimage', 'rejected'):
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        server.phase = 'authorize'; server.calls = []; server.scenario = scenario; server.preflight_read = False; server.private_paths=[]
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}', scenario], check=True, timeout=15)
            if scenario == 'bindingmissing':
                assert not server.calls
            else:
                assert 'agent_cli_tool_receipt' in server.calls
                assert server.calls.count('agent_cli_start')==1 and server.calls.count('agent_cli_tool_receipt')==1
                if scenario.startswith('hostunknown'): assert all(path.exists() for path in server.private_paths)
        finally:
            server.shutdown(); server.server_close(); thread.join()
            for path in server.private_paths:
                if path.exists(): shutil.rmtree(path) # Only this fixture's owned private cwd.
