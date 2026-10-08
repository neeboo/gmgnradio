#!/usr/bin/env python3
"""Isolated Swift 6 client against a real loopback HTTP fixture; no GUI/audio."""
import http.server
import json
import hashlib
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
        result = {'accepted': True}
        if method == 'agent_runtime_configure':
            assert p['dynamicAuthorization'] is True and p['operations'] == []
            assert p['provider']['imageInput'] is (self.server.scenario == 'images')
        elif method == 'agent_runtime_start':
            assert p['images'] == [{'mediaType': 'image/png', 'base64': 'AQID'}]
        elif method == 'agent_runtime_steer':
            assert p['inputRef'] == {'submissionID': 'guide', 'inputSHA256': hashlib.sha256(p['input'].encode()).hexdigest(), 'imageReferences': []}
            assert p['operations'] == [] and p['eventID'] == 'event'
            duplicate = self.server.steered is not None
            if duplicate:
                assert p == self.server.steered
            self.server.steered = p
            result = {'delivery': 'delivered', 'duplicate': duplicate, 'grantsApplied': True}
        elif method == 'agent_runtime_authorize':
            assert p['operationID'] == 'business-operation'
            self.server.phase = 'execute'
        elif method == 'agent_runtime_tool_receipt':
            assert p['callID'] == 'call' and p['operationID'] == 'business-operation'
            assert p['output'] == {'ok': True}
            if self.server.scenario == 'images':
                assert p['images'] == [{'mediaType': 'image/jpeg', 'base64': '/wABgA=='}]
            else:
                assert 'images' not in p
            self.server.phase = 'done'
        elif method == 'agent_runtime_cancel':
            self.server.phase = 'cancelled'
        elif method == 'agent_runtime_read':
            phase = self.server.phase
            tool = {k: p[k] for k in ('worldID', 'residentScope', 'hostSessionID', 'runID')}
            tool.update(callID='call', toolName='move', arguments={}, phase=phase)
            if phase == 'execute':
                tool['operationID'] = 'business-operation'
            result = {'state': 'completed' if phase == 'done' else 'cancelled' if phase == 'cancelled' else 'running',
                      'text': 'same text', 'pendingTools': [] if phase in ('done', 'cancelled') else [tool]}
        data = json.dumps(result).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(data)

with tempfile.TemporaryDirectory(prefix='gmgn-rutis-swift-') as directory:
    binary = pathlib.Path(directory) / 'test'
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library',
                    str(ROOT / 'apps/macos/Sources/GMGNRadio/Presence/RustAgentRuntimeClient.swift'),
                    str(pathlib.Path(__file__).with_suffix('.swift')), '-o', str(binary)], check=True)
    for scenario in ('normal', 'wrong', 'cancel', 'steer', 'images'):
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        server.phase = 'authorize'; server.calls = []; server.steered = None
        server.scenario = scenario
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}', scenario], check=True, timeout=15)
            if scenario == 'wrong':
                assert 'agent_runtime_tool_receipt' not in server.calls
            if scenario == 'cancel':
                assert 'agent_runtime_authorize' not in server.calls
                assert 'agent_runtime_tool_receipt' not in server.calls
                assert 'agent_runtime_cancel' in server.calls
            if scenario == 'steer':
                assert server.calls.count('agent_runtime_steer') == 2
        finally:
            server.shutdown(); server.server_close(); thread.join()
