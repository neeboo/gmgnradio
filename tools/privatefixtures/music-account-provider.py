#!/usr/bin/env python3
"""Loopback-only raw provider replies for private XCTest taskd instances."""
import http.server, json, pathlib, sys, threading
endpoint, requests = map(pathlib.Path, sys.argv[1:3])
class Provider(http.server.BaseHTTPRequestHandler):
    def respond(self):
        length = int(self.headers.get('Content-Length', '0'))
        self.rfile.read(length)
        expired = 'expired' in self.headers.get('Cookie', '')
        # Preserve raw provider response shape; Rust owns validity decisions.
        if 'nuser/account/get' in self.path:
            body = {'profile': None if expired else {'userId': 42}}
        elif 'fcg_user_created_diss' in self.path:
            body = {'code': 100 if expired else 0, 'data': {'disslist': []}}
        else:
            self.send_error(404); return
        with requests.open('a') as output:
            output.write(json.dumps({'method': self.command, 'path': self.path,
                'thread': threading.current_thread().name}) + '\n')
        data = json.dumps(body).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
    do_POST = respond
    do_GET = respond
    def log_message(self, *args): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider)
endpoint.write_text(json.dumps({'baseURL': f'http://127.0.0.1:{server.server_port}'}))
server.serve_forever()
