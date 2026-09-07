#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Serve an explicit site directory on loopback, optionally outside this terminal."""
import argparse
import hashlib
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.request
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]

class MediaHandler(SimpleHTTPRequestHandler):
    def translate_path(self, path):
        aliases = {
            '/icon.png': ROOT/'Resources/Marketing/app-icon.png',
            '/content/en/CLI.md': ROOT/'docs/CLI.md',
            '/content/en/CONFIGURATION.md': ROOT/'docs/CONFIGURATION.md',
        }
        # Source previews and production builds read the same public inputs.
        if Path(self.directory).resolve() == ROOT/'web' and urlsplit(path).path in aliases:
            return str(aliases[urlsplit(path).path])
        return super().translate_path(path)

    def end_headers(self):
        # HTML must discover the current content-hashed media URLs on each visit.
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('X-Tatami-Preview-PID', str(os.getpid()))
        self.send_header('X-Tatami-Preview-Root', hashlib.sha256(str(Path(self.directory).resolve()).encode()).hexdigest())
        super().end_headers()

    def send_head(self):
        self.remaining = None
        value = self.headers.get('Range')
        path = Path(self.translate_path(self.path))
        if not value or not path.is_file():
            return super().send_head()
        size = path.stat().st_size
        match = re.fullmatch(r'bytes=(\d*)-(\d*)', value)
        if not match or not any(match.groups()):
            self.send_error(416, 'Invalid byte range')
            return None
        first, last = match.groups()
        start = int(first) if first else max(0, size - int(last))
        end = min(int(last), size - 1) if first and last else size - 1
        if start > end or start >= size:
            self.send_response(416)
            self.send_header('Content-Range', f'bytes */{size}')
            self.end_headers()
            return None
        file = path.open('rb')
        file.seek(start)
        self.remaining = end - start + 1
        self.send_response(206)
        self.send_header('Content-Type', self.guess_type(str(path)))
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.send_header('Content-Length', str(self.remaining))
        self.end_headers()
        return file

    def copyfile(self, source, outputfile):
        if self.remaining is None:
            return super().copyfile(source, outputfile)
        while self.remaining:
            data = source.read(min(65536, self.remaining))
            if not data:
                break
            outputfile.write(data)
            self.remaining -= len(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=ROOT / 'web')
    parser.add_argument('--port', type=int, default=8769)
    parser.add_argument('--background', action='store_true')
    args = parser.parse_args()
    directory = args.directory.resolve()
    if not (directory / 'index.html').is_file():
        parser.error(f'index.html is missing in {directory}')
    url = f'http://127.0.0.1:{args.port}/'
    if args.background:
        expected_root = hashlib.sha256(str(directory).encode()).hexdigest()
        try:
            with urllib.request.urlopen(url, timeout=.3) as existing:
                if existing.headers.get('X-Tatami-Preview-Root') == expected_root:
                    print(f'{url} (already serving {directory})')
                    return
                parser.error('port is occupied by another server; use another port')
        except OSError:
            pass
        state = ROOT / '.build/site-preview'
        state.mkdir(parents=True, exist_ok=True)
        with (state / f'{args.port}.log').open('ab') as log:
            process = subprocess.Popen([sys.executable, __file__, '--directory', str(directory), '--port', str(args.port)],
                                       stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True, close_fds=True)
        for _ in range(50):
            if process.poll() is not None:
                parser.error(f'server exited; inspect {state / f"{args.port}.log"}')
            try:
                with urllib.request.urlopen(url, timeout=.2) as response:
                    if response.status == 200 and response.headers.get('X-Tatami-Preview-PID') == str(process.pid):
                        (state / f'{args.port}.pid').write_text(str(process.pid))
                        print(f'{url} (PID {process.pid}; serving {directory})')
                        return
            except OSError:
                time.sleep(.1)
        process.terminate()
        parser.error('server did not become ready')
    server = ThreadingHTTPServer(('127.0.0.1', args.port), partial(MediaHandler, directory=str(directory)))
    print(f'{url} → {directory}', flush=True)
    server.serve_forever()

if __name__ == '__main__':
    main()
