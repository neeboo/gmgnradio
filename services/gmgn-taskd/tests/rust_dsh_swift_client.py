#!/usr/bin/env python3
"""Swift DSH consumer and native per-run token schema, over isolated HTTP."""
import http.server
import json
import pathlib
import subprocess
import tempfile
import threading

ROOT = pathlib.Path(__file__).resolve().parents[3]

class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        p = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        method = self.path.rsplit('/', 1)[-1]; self.server.calls.append(method)
        result = {'accepted': True}
        assert {k: p[k] for k in ('worldID', 'residentScope', 'hostSessionID', 'runID', 'eventID')} == {
            'worldID': 'w', 'residentScope': 's', 'hostSessionID': 'h', 'runID': 'r', 'eventID': 'e'}
        if method == 'agent_dsh_start':
            assert p['arguments'] == [p['entryPoint'], '--config', p['compositionFile']]
            assert p['input'] == 'test' and p['tools'][0]['effect'] == 'write'
            result = {'started': True, 'grantToken': 'other' if self.server.scenario == 'wrongtoken' else p['grantToken']}
        elif method == 'agent_dsh_authorize':
            assert p['acpSessionID'] == 'acp' and p['operationID'] == 'business-op'
            self.server.phase = 'execute'
        elif method == 'agent_dsh_tool_receipt':
            assert p['acpSessionID'] == 'acp' and p['operationID'] == 'business-op' and p['output'] == {'ok': True}
            if self.server.scenario == 'images':
                assert p['images'][0]['mediaType'] == 'image/png' and p['images'][0]['base64'].startswith('iVBORw0KGgo')
            else:
                assert 'images' not in p
            self.server.phase = 'done'
        elif method == 'agent_dsh_cancel':
            self.server.phase = 'cancelled'
        elif method == 'agent_dsh_read':
            phase = self.server.phase
            item = dict(p, acpSessionID='acp', callID='call', toolName='move', arguments={}, phase=phase)
            if phase == 'execute':
                item['operationID'] = 'business-op'
                if self.server.scenario == 'wrongsession':
                    item['acpSessionID'] = 'other'
            state = 'completed' if phase == 'done' else 'cancelled' if phase == 'cancelled' else 'running'
            if self.server.scenario == 'unknown':
                state = 'unknown'
            result = {'state': state, 'text': 'hello world' if phase == 'done' else 'hello',
                      'pendingTools': [] if state != 'running' else [item], 'acpSessionID': 'acp'}
        data = json.dumps(result).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(data)

with tempfile.TemporaryDirectory(prefix='gmgn-dsh-swift-') as directory:
    directory = pathlib.Path(directory)
    http_source = directory / 'http.swift'
    http_source.write_text(pathlib.Path(__file__).with_name('rust_codex_swift_client.swift').read_text().split('actor CLISink')[0])
    binary = directory / 'test'
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(http_source),
                    str(ROOT / 'apps/macos/Sources/GMGNRadio/Presence/RustCodexSessionClient.swift'),
                    str(ROOT / 'apps/macos/Sources/GMGNRadio/Presence/RustDSHSessionClient.swift'),
                    str(pathlib.Path(__file__).with_suffix('.swift')), '-o', str(binary)], check=True)
    for scenario in ('normal', 'wrongreceipt', 'wrongsession', 'wrongtoken', 'cancel', 'unknown', 'images'):
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        server.phase = 'authorize'; server.calls = []; server.scenario = scenario
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}', scenario], check=True, timeout=15)
            if scenario not in ('normal', 'images'):
                assert 'agent_dsh_tool_receipt' not in server.calls
            if scenario == 'cancel':
                assert 'agent_dsh_cancel' in server.calls and 'agent_dsh_authorize' not in server.calls
            if scenario == 'unknown':
                assert server.calls.count('agent_dsh_start') == 1
        finally:
            server.shutdown(); server.server_close(); thread.join()
