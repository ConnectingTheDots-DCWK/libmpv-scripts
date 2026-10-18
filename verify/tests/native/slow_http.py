#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""
Minimal HTTP file server with Range support and a byte rate limit, for the
native tests that read a file over HTTP. Logs one line per GET to stderr.

Usage: slow_http.py <dir> <port> <bytes per second> [cut]

With cut, the first response that reaches byte offset cut of the file stops
there and closes the connection, and a request to resume from cut gets 503
(a download cut short for good).
"""
import http.server, os, sys, time, re
ROOT, PORT, RATE = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
CUT = int(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else 0
cut_done = False
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global cut_done
        p = os.path.join(ROOT, os.path.basename(self.path))
        size = os.path.getsize(p)
        start, end = 0, size - 1
        m = re.match(r'bytes=(\d+)-(\d*)', self.headers.get('Range', ''))
        if m:
            start = int(m.group(1)); end = int(m.group(2)) if m.group(2) else size - 1
        if CUT and cut_done and start == CUT:
            sys.stderr.write(f'GET {self.path} range={start}- refused\n')
            self.send_response(503); self.send_header('Content-Length', '0'); self.end_headers()
            return
        if m:
            self.send_response(206); self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        else:
            self.send_response(200)
        self.send_header('Content-Length', str(end - start + 1)); self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Type', 'audio/flac'); self.end_headers()
        sys.stderr.write(f'GET {self.path} range={start}-{end}\n')
        with open(p, 'rb') as f:
            f.seek(start); left = end - start + 1; pos = start
            try:
                while left > 0:
                    n = min(16384, left)
                    if CUT and not cut_done and pos < CUT <= pos + n:
                        cut_done = True
                        self.wfile.write(f.read(CUT - pos))
                        sys.stderr.write(f'CUT at {CUT}\n')
                        break
                    b = f.read(n); self.wfile.write(b); left -= len(b); pos += len(b); time.sleep(len(b) / RATE)
            except (BrokenPipeError, ConnectionResetError):
                pass
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
