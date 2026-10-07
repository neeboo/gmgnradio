import http.server
import os
import pathlib
import sys

root = pathlib.Path.home() / 'Library/Application Support/gmgn radio/TaskService/media-cache'
key = '2cd64660b7194e39dd65d4e990feef162c6a5d453c20093572a26f3ced52b066'
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_GET(self):
        kind = self.path.rsplit('/', 1)[-1]
        if kind not in ('video', 'audio', 'muxed'):
            self.send_error(404)
            return
        path = pathlib.Path(os.environ.get('GMGN_EOF_MUXED_FILE', '/tmp/gmgn-youtube-third-muxed-eof-20261007.mp4')) if kind == 'muxed' else root / (key + ('.video.mp4' if kind == 'video' else '.audio.m4a'))
        size = path.stat().st_size
        start, end = 0, size - 1
        if self.headers.get('Range'):
            parts = self.headers['Range'].removeprefix('bytes=').split('-')
            start = int(parts[0]); end = min(int(parts[1]) if parts[1] else end, end)
        if start >= size:
            self.send_error(416)
            return
        self.send_response(206)
        self.send_header('Content-Type', 'audio/mp4' if kind == 'audio' else 'video/mp4')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.send_header('Content-Length', str(end-start+1))
        self.end_headers()
        with path.open('rb') as media:
            media.seek(start)
            self.wfile.write(media.read(end-start+1))

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
