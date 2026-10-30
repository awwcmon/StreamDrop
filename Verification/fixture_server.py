import argparse
import http.server
import json
import pathlib
import re
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument("media", type=pathlib.Path)
parser.add_argument("--port", type=int, default=18739)
parser.add_argument("--alternate-media", type=pathlib.Path)
args = parser.parse_args()
media = args.media.read_bytes()
alternate_media = args.alternate_media.read_bytes() if args.alternate_media else None


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.respond(True)

    def do_HEAD(self):
        self.respond(False)

    def respond(self, body):
        if self.path == "/shutdown":
            self.send_response(200)
            self.end_headers()
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        payload = alternate_media if self.path == "/vp9.webm" else media
        if self.path not in ("/sample.mp4", "/slow.mp4", "/vp9.webm") or payload is None:
            self.send_error(404)
            return
        start, end = 0, len(payload) - 1
        header = self.headers.get("Range")
        if header:
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", header)
            if not match:
                self.send_error(416)
                return
            start = int(match[1])
            end = min(int(match[2]) if match[2] else end, end)
        if start > end:
            self.send_error(416)
            return
        self.send_response(206 if header else 200)
        self.send_header("Content-Type", "video/webm" if self.path == "/vp9.webm" else "video/mp4")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        if header:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(payload)}")
        self.end_headers()
        if not body:
            return
        print(json.dumps({"path": self.path, "range": header, "bytes": end - start + 1}), flush=True)
        try:
            for offset in range(start, end + 1, 16384):
                self.wfile.write(payload[offset:min(offset + 16384, end + 1)])
                self.wfile.flush()
                if self.path == "/slow.mp4":
                    time.sleep(0.12)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, format, *values):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
print(f"Fixture server ready: http://127.0.0.1:{server.server_port}", flush=True)
server.serve_forever()
server.server_close()
