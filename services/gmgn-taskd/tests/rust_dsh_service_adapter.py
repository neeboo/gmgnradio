#!/usr/bin/env python3
"""Production DSH consumer, original plugin and actual composition, no CLI launch."""
import http.server
import json
import pathlib
import stat
import subprocess
import tempfile
import threading
import uuid
import shutil

ROOT = pathlib.Path(__file__).resolve().parents[3]
APP = ROOT / 'apps/macos/Sources/GMGNRadio'

def declaration(source, marker):
    start = source.index(marker); brace = source.index('{', start); depth = 1; end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[start:end]

namespace = {'__file__': str(pathlib.Path(__file__).with_name('rust_dsh_swift_client.py'))}
exec(pathlib.Path(namespace['__file__']).read_text().split('with tempfile.TemporaryDirectory')[0], namespace)
BaseFixture = namespace['Fixture']

class Fixture(BaseFixture):
    def do_POST(self):
        if self.path.endswith('agent_dsh_read') and self.server.phase == 'hostunknown':
            self.rfile.read(int(self.headers['Content-Length'])); self.server.calls.append('agent_dsh_read')
            data=json.dumps({'state':'unknown','text':'hello','acpSessionID':'acp','pendingTools':[]}).encode()
            self.send_response(200);self.end_headers();self.wfile.write(data);return
        if self.path.endswith('agent_dsh_start') or self.path.endswith('agent_dsh_tool_receipt'):
            p = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            method = self.path.rsplit('/', 1)[-1]; self.server.calls.append(method)
            if method == 'agent_dsh_start':
                assert p['arguments'] == [p['entryPoint'], '--config', p['compositionFile']]
                assert p['executable'] == '/usr/bin/true' and p['input'] == 'test'
                assert pathlib.Path(p['cwd']) == pathlib.Path(p['cwd']).resolve()
                plugin = pathlib.Path(p['hostToolsPlugin']); grant_path = plugin.with_name('gmgn-host-tools.grant.json')
                grant = json.loads(grant_path.read_text())
                assert uuid.UUID(p['grantToken']).version == 4
                assert grant['secret'] == grant['endpoint']['token'] == p['grantToken']
                assert grant['endpoint']['url'] == f'http://127.0.0.1:{self.server.server_port}/rpc'
                assert grant['state'] == 'armed' and grant['tools'][0]['name'] == 'gmgn_move'
                assert stat.S_IMODE(grant_path.stat().st_mode) == 0o600
                bootstrap = json.loads(plugin.with_name('gmgn-host-tools.bootstrap.json').read_text())
                assert bootstrap['tools'] == grant['tools']
                assert 'JSON.stringify({ v: 1, callId:' in plugin.read_text(), 'must retain native flat plugin'
                composition = pathlib.Path(p['compositionFile']).read_text()
                assert "tools:\n      mode: native" in composition and str(plugin) in composition
                assert p['tools'][0]['effect'] == 'write'
                self.server.private_paths = [plugin.parent, pathlib.Path(p['root'])]
                result = {'started': True, 'grantToken': p['grantToken']}
            else:
                assert p['acpSessionID'] == 'acp' and p['operationID'] == 'business-op'
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
methods = declaration(source, '    private func sendRustDSHResident(') + '\n' + declaration(source, '    private func recordRustResidentFailure(') + '\n' + declaration(source, '    nonisolated static func rustHostReceiptStatus(')
bridge = (APP / 'Agent/ResidentDSHHostToolsBridge.swift').read_text()
registrations = declaration(bridge, 'public struct ResidentDSHHostToolRegistration:') + '\n' + declaration(bridge, 'public enum ResidentDSHHostToolSet ')
plugin = bridge[bridge.index('public enum ResidentDSHHostToolsPlugin '):bridge.index('// MARK: - Host channel')]
http_source = pathlib.Path(__file__).with_name('rust_codex_swift_client.swift').read_text().split('actor CLISink')[0]
stubs = '''
struct ResidentVisionImage: Sendable { let pngData: Data }
struct ResidentCodexToolReply: Sendable { let resultJSON: Data; let isError: Bool; var image: ResidentVisionImage? }
struct AgentConversationMessage: Sendable {}
struct ResidentDSHImageBlock { let data: Data; let mimeType: String }
enum AgentConversationError: Error { case dshSecurityPatchUnavailable }
enum ResidentDSHHostToolsError: Error { case malformedToolSet(String) }
protocol AgentExecutableLocating { func locate(executableNames: [String]) -> URL? }
struct FixtureLocator: AgentExecutableLocating { func locate(executableNames: [String]) -> URL? { executableNames == ["node"] ? URL(fileURLWithPath: "/usr/bin/true") : nil } }
@MainActor final class AgentConversationService {
    let locator = FixtureLocator()
    var currentRustDSHClient: RustDSHSessionClient?
    var currentRustDSHGrantURL: URL?
    var lastResidentFailure: [String: Any] = [:]
    var residentFailureHistory: [[String: Any]] = []
    static let residentFailureHistoryLimit = 8
    static func dshNativeImageBlocks(_ urls: [URL]) throws -> [ResidentDSHImageBlock] { [] }
    static func dshPrompt(text: String, history: [AgentConversationMessage]) -> String { text }
    func testSend(scope: String, tools: ResidentConversationTools) async throws -> String {
        try await sendRustDSHResident(runtimeScope: scope, prompt: "test", imageURLs: [], history: [], tools: tools)
    }
'''
with tempfile.TemporaryDirectory(prefix='gmgn-dsh-adapter-') as directory:
    directory = pathlib.Path(directory).resolve()
    entry = directory / 'installation/runtime.mjs'; entry.parent.mkdir(); entry.write_text('// Never executed.\n')
    for name in ('dsh-llm-deepseek', 'dsh-credentials-local', 'dsh-attachment-local', 'dsh-acp-demo', 'dsh-web', 'dsh-web-fetch-http', 'dsh-web-search-deepseek', 'dsh-tool-web'):
        package = entry.parent / 'node_modules/@deepseek-ai' / name; package.mkdir(parents=True)
        (package / 'package.json').write_text(json.dumps({'name': '@deepseek-ai/' + name}))
    generated = directory / 'adapter.swift'
    generated.write_text(http_source + '\n' + registrations + '\n' + plugin + '\n' + bindings + '\n' + stubs + '\n' + methods + '\n}\n')
    binary = directory / 'test'
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(generated),
                    str(APP / 'Presence/RustCodexSessionClient.swift'), str(APP / 'Presence/RustDSHSessionClient.swift'),
                    str(APP / 'Presence/RustResidentClaudeClient.swift'),
                    str(APP / 'Agent/ResidentDSHConfiguration.swift'), str(pathlib.Path(__file__).with_suffix('.swift')),
                    '-o', str(binary)], check=True)
    for scenario in ('adapter', 'bindingmissing', 'hostunknown'):
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        server.phase = 'authorize'; server.calls = []; server.scenario = scenario; server.private_paths = []
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}', scenario, str(entry)], check=True, timeout=15)
            if scenario == 'bindingmissing':
                assert not server.calls
            else:
                assert 'agent_dsh_tool_receipt' in server.calls
                assert server.calls.count('agent_dsh_start')==1 and server.calls.count('agent_dsh_tool_receipt')==1
                if scenario=='hostunknown':
                    assert all(path.exists() for path in server.private_paths), 'unknown must retain owned files'
                else: assert not any(path.exists() for path in server.private_paths), 'confirmed terminal must clean owned private files'
        finally:
            server.shutdown(); server.server_close(); thread.join()
            for path in server.private_paths:
                if path.exists(): shutil.rmtree(path) # Only private paths created by this fixture invocation.
