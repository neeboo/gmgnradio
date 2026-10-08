#!/usr/bin/env python3
"""Swift client protocol tests over loopback HTTP; never launches Codex."""
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
        method = self.path.rsplit('/', 1)[-1]
        self.server.calls.append(method)
        assert {k: p[k] for k in ('worldID', 'residentScope', 'hostSessionID', 'runID', 'eventID')} == {
            'worldID': 'w', 'residentScope': 's', 'hostSessionID': 'h', 'runID': 'r', 'eventID': 'e'}
        result = {'accepted': True}
        if method == 'agent_cli_start':
            assert p['executable'] == '/fixture/codex' and p['resumeThreadID'] == 'thread'
            assert p['environment'] == {'LANG': 'C'}
            overrides = [f'features.{name}=false' for name in ('plugins', 'apps', 'hooks', 'multi_agent', 'multi_agent_v2', 'image_generation', 'shell_tool')]
            overrides += ['agents.enabled=false', 'notify=[]', 'web_search="live"', 'cli_auth_credentials_store="file"', 'mcp_oauth_credentials_store="file"']
            assert p['arguments'] == ['app-server', '--stdio'] + [part for item in overrides for part in ('-c', item)]
            assert p['input'] == [{'type': 'text', 'text': 'test', 'text_elements': []},
                                  {'type': 'image', 'url': 'data:image/png;base64,AQID'},
                                  {'type': 'localImage', 'path': '/fixture/image.png'}]
        elif method == 'agent_cli_authorize':
            assert p['operationID'] == 'business-op' and p['threadID'] == 'thread' and p['turnID'] == 'turn'
            self.server.phase = 'execute'
        elif method == 'agent_cli_tool_receipt':
            assert p['threadID'] == 'thread' and p['turnID'] == 'turn' and p['callID'] == 'call'
            assert p['output'] == {'ok': True}
            if self.server.scenario == 'images':
                assert p['images'] == [{'mediaType': 'image/png', 'base64': 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZAAAAABJRU5ErkJggg=='}]
            else:
                assert 'images' not in p
            self.server.phase = 'done'
        elif method == 'agent_cli_cancel':
            self.server.phase = 'cancelled'
        elif method == 'agent_cli_read':
            if not self.server.preflight_read:
                self.server.preflight_read = True
                result = {'state': 'preflight', 'text': '', 'pendingTools': [], 'threadID': None, 'turnID': None}
                data = json.dumps(result).encode()
                self.send_response(200); self.end_headers(); self.wfile.write(data)
                return
            phase = self.server.phase
            item = dict(p, threadID='thread', turnID='turn', callID='call', toolName='move', arguments={}, phase=phase)
            if phase == 'execute':
                item['operationID'] = 'business-op'
                if self.server.scenario == 'wrongturn':
                    item['turnID'] = 'different'
            state = 'completed' if phase == 'done' else 'cancelled' if phase == 'cancelled' else 'running'
            if self.server.scenario == 'unknown':
                state = 'unknown'
            result = {'state': state, 'text': 'hello world' if phase == 'done' else 'hello',
                      'threadID': 'thread', 'turnID': 'turn',
                      'pendingTools': [] if state != 'running' else [item]}
        data = json.dumps(result).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(data)

with tempfile.TemporaryDirectory(prefix='gmgn-cli-swift-') as directory:
    binary = pathlib.Path(directory) / 'test'
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library',
                    str(ROOT / 'apps/macos/Sources/GMGNRadio/Presence/RustCodexSessionClient.swift'),
                    str(ROOT / 'apps/macos/Sources/GMGNRadio/Agent/ResidentCodexPolicy.swift'),
                    str(pathlib.Path(__file__).with_suffix('.swift')), '-o', str(binary)], check=True)
    for scenario in ('normal', 'wrongreceipt', 'wrongturn', 'cancel', 'unknown', 'images'):
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        server.phase = 'authorize'; server.calls = []; server.scenario = scenario
        server.preflight_read = False
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}', scenario], check=True, timeout=15)
            if scenario not in ('normal', 'images'):
                assert 'agent_cli_tool_receipt' not in server.calls
            if scenario == 'cancel':
                assert 'agent_cli_authorize' not in server.calls
                assert 'agent_cli_cancel' in server.calls
            if scenario == 'unknown':
                assert server.calls.count('agent_cli_start') == 1
        finally:
            server.shutdown(); server.server_close(); thread.join()
