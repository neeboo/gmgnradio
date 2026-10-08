#!/usr/bin/env python3
"""Production Claude adapter methods with UI stubs, actual HTTP and no subprocess model."""
import http.server
import json
import pathlib
import subprocess
import tempfile
import threading

ROOT = pathlib.Path(__file__).resolve().parents[3]
APP = ROOT / 'apps/macos/Sources/GMGNRadio'

def declaration(source, marker):
    start = source.index(marker); brace = source.index('{', start); depth = 1; end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[start:end]

namespace = {'__file__': str(pathlib.Path(__file__).with_name('rust_claude_swift_client.py'))}
exec(pathlib.Path(namespace['__file__']).read_text().split('with tempfile.TemporaryDirectory')[0], namespace)
BaseFixture = namespace['Fixture']

class Fixture(BaseFixture):
    def do_POST(self):
        if self.path.endswith('agent_claude_read') and self.server.phase == 'hostunknown':
            self.rfile.read(int(self.headers['Content-Length']));self.server.calls.append('agent_claude_read')
            data=json.dumps({'state':'unknown','text':'hello','round':'round-1','pendingTools':[]}).encode()
            self.send_response(200);self.end_headers();self.wfile.write(data);return
        if self.path.endswith('agent_claude_start') or self.path.endswith('agent_claude_tool_receipt'):
            p = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            method = self.path.rsplit('/', 1)[-1]; self.server.calls.append(method)
            if method == 'agent_claude_start':
                assert p['executable'] == '/usr/bin/true' and p['adapterExecutable'] == '/usr/bin/true'
                assert p['input'] == 'test' and p['durableUserText'] == 'user' and p['memoryContext'] == 'memory'
                assert p['tools'][0]['effect'] == 'write' and p['environment'] == {'ANTHROPIC_API_KEY': 'fixture-only-not-a-key'}
                assert p['hostEndpoint'] == f'http://127.0.0.1:{self.server.server_port}/rpc'
                assert not any(k in p for k in ('arguments', 'mcpConfig', 'images', 'resumeThreadID'))
                result = {'started': True}
            else:
                assert p['round'] == 'round-1' and p['operationID'] == 'business-op'
                if self.server.scenario=='hostunknown':
                    assert p['status']=='unknown' and p['output']=={'ok':False,'code':'world_prop_execution_unknown'} and 'images' not in p
                    self.server.phase='hostunknown'
                else:
                    assert p['status']=='completed' and p['output'] == {'ok': True} and p['images'][0]['mediaType'] == 'image/png'
                    assert p['images'][0]['base64'].startswith('iVBORw0KGgo')
                    self.server.phase = 'done'
                result = {'accepted': True}
            data = json.dumps(result).encode(); self.send_response(200); self.end_headers(); self.wfile.write(data)
        else:
            super().do_POST()

source = (APP / 'Agent/AgentConversationService.swift').read_text()
bindings = '\n'.join(declaration(source, marker) for marker in ('struct RustResidentToolBinding:', 'struct RustResidentDSHToolBinding:', 'struct RustResidentClaudeToolBinding:', 'struct ResidentConversationTools:'))
methods = declaration(source, '    private func sendRustClaudeResident(') + '\n' + declaration(source, '    private func recordRustResidentFailure(') + '\n' + declaration(source, '    nonisolated static func rustHostReceiptStatus(')
bridge = (APP / 'Agent/ResidentDSHHostToolsBridge.swift').read_text()
registrations = declaration(bridge, 'public struct ResidentDSHHostToolRegistration:') + '\n' + declaration(bridge, 'public enum ResidentDSHHostToolSet ')
http_source = pathlib.Path(__file__).with_name('rust_codex_swift_client.swift').read_text().split('actor CLISink')[0]
stubs = '''
struct ResidentVisionImage: Sendable { let pngData: Data }
struct ResidentCodexToolReply: Sendable { let resultJSON: Data; let isError: Bool; var image: ResidentVisionImage? }
struct AgentConversationOutcome { let reply: String; let sessionID: String? }
enum AgentConversationError: Error { case claudeInvalidResult }
enum ResidentDSHHostToolsError: Error { case malformedToolSet(String) }
@MainActor final class AgentConversationService {
    var currentRustClaudeClient: RustResidentClaudeClient?
    var lastResidentFailure: [String: Any] = [:]
    var residentFailureHistory: [[String: Any]] = []
    static let residentFailureHistoryLimit = 8
    func testSend(tools: ResidentConversationTools) async throws -> AgentConversationOutcome {
        try await sendRustClaudeResident(executable: URL(fileURLWithPath: "/usr/bin/true"), input: "test", durableUserText: "user", memoryContext: "memory", tools: tools)
    }
'''
with tempfile.TemporaryDirectory(prefix='gmgn-claude-adapter-') as directory:
    directory = pathlib.Path(directory)
    generated = directory / 'adapter.swift'
    generated.write_text(http_source + '\n' + registrations + '\n' + bindings + '\n' + stubs + '\n' + methods + '\n}\n')
    binary = directory / 'test'
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(generated),
                    str(APP / 'Presence/RustCodexSessionClient.swift'), str(APP / 'Presence/RustDSHSessionClient.swift'),
                    str(APP / 'Presence/RustResidentClaudeClient.swift'), str(pathlib.Path(__file__).with_suffix('.swift')),
                    '-o', str(binary)], check=True)
    for scenario in ('adapter', 'bindingmissing', 'wrongeffects', 'cancel', 'unknown', 'hostunknown'):
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        server.phase = 'authorize'; server.calls = []; server.scenario = scenario
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}', scenario], check=True, timeout=15)
            if scenario in ('bindingmissing', 'wrongeffects'):
                assert not server.calls
            if scenario == 'cancel':
                assert 'agent_claude_cancel' in server.calls and 'agent_claude_authorize' not in server.calls
            if scenario == 'unknown':
                assert 'agent_claude_tool_receipt' not in server.calls
        finally:
            server.shutdown(); server.server_close(); thread.join()
