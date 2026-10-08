"""Private DTO mock only; real ledger/placement tests belong to taskd."""
import http.server
import json
import pathlib
import sys
import uuid

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
token = str(uuid.uuid4())
registration_output = None

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        global registration_output
        if self.path != '/rpc' or self.headers.get('Authorization') != 'Bearer ' + token:
            self.send_error(401)
            return
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        method, p = request['method'], request['params']
        assert p['worldID'] == 'fixture-world'
        result = {'ok': True}
        error = None
        if method == 'world_snapshot':
            result = {'record': {'recordRevision': 7}}
        else:
            assert p['residentScope'] == 'fixture-scope' and p['hostSessionID'] == 'fixture-host'
        if method == 'world_prop_observe':
            assert p['expectedRevision'] == 7 and p['layoutRevision'] == 3
            assert p['facts'] == {'rawFixtureFact': True}
            result = {'geometryID': 'fixture-geometry', 'meshSHA256': 'a' * 64, 'layoutRevision': 3}
        elif method == 'world_prop_command':
            assert not set(p).intersection({'command', 'allowed', 'allowsMutation', 'candidate', 'checkpoint'})
            assert p['expectedRevision'] == 7 and p['expectedLayoutRevision'] == 3
            authority = p['authority']
            if authority['kind'] == 'agent':
                assert authority['runID'] == 'fixture-run' and authority['callID'] == 'fixture-call'
                if authority['operationID'] != 'fixture-operation':
                    error = {'code': 'world_prop_unauthorized'}
            else:
                assert authority == {'kind': 'ui', 'intentID': 'fixture-intent', 'capability': 'fixture-capability'}
        elif method == 'world_prop_ui_intent':
            assert p['command']['op'] == 'place'
            result = {'intentID': 'fixture-intent', 'capability': 'fixture-capability', 'expiresAtMS': 10000}
        elif method == 'world_prop_preview':
            assert p['command']['surfaceID'] == 'grid.layer.0'
        elif method == 'world_prop_surfaces':
            assert p['geometryID'] == 'fixture-geometry'
        elif method == 'world_prop_register':
            assert registration_output is None, 'Lost response must be reconciled, never dispatched twice'
            assert set(p) == {'worldID', 'residentScope', 'hostSessionID', 'wishID', 'expectedRevision', 'expectedLayoutRevision', 'requestID', 'measurement'}
            assert p['measurement'] == {'blobRef': 'sha256:' + 'b' * 64, 'triangles': [[[0, 0, 0], [1, 0, 0], [0, 1, 0]]]}
            registration_output = {'prop': {'objectID': 'registered'}, 'snapshot': {'record': {'recordRevision': 8}}}
            # Commit acknowledged by the mock's durable-journal stand-in, HTTP response lost.
            self.close_connection = True
            return
        elif method == 'world_prop_receipt':
            assert p['requestID'] == 'original-register-request'
            result = {'found': True, 'output': registration_output}
        reply = {'id': request['id']}
        reply['error' if error else 'result'] = error or result
        data = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
(root / 'taskd.endpoint.json').write_text(json.dumps({'version': 2, 'address': '127.0.0.1:' + str(server.server_port), 'token': token}))
server.serve_forever()
