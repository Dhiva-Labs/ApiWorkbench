"""Local deterministic endpoint for Android release smoke tests.

Run: python3 tool/mobile_fixture.py
Then: adb reverse tcp:8765 tcp:8765
Enter http://127.0.0.1:8765/echo in ApiWorkbench on the emulator.
"""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def respond(self):
        path = urlparse(self.path)
        if path.path == '/slow':
            time.sleep(5)
        data = {
            'message': 'Android release request succeeded',
            'method': self.command,
            'query': parse_qs(path.query),
            'body': self.rfile.read(int(self.headers.get('Content-Length', '0'))).decode(),
        }
        if path.path == '/large':
            data['payload'] = 'x' * (2 * 1024 * 1024)
        payload = json.dumps(data).encode()
        self.send_response(422 if path.path == '/status' else 200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.send_header('X-Device-Test', 'release')
        self.end_headers()
        try:
            self.wfile.write(payload)
        except BrokenPipeError:
            pass


if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', 8765), Handler).serve_forever()
