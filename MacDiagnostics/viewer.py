"""Live Mac diagnostics for Audible Environment."""
import base64
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
from threading import Lock, Thread

PORT = 8766
def viewer_code():
    local = Path(__file__).resolve().parent.parent / "Audible Enviornment/LocalViewerCode.txt"
    if local.is_file():
        return local.read_text().strip()
    directory = Path.home() / "Library/Application Support/Audible Environment"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = directory / "viewer-code"
    try:
        with os.fdopen(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), "w") as file:
            file.write(secrets.token_urlsafe(12))
    except FileExistsError:
        pass
    return path.read_text().strip()


CODE = viewer_code()
lock = Lock()
latest = {}


class Receiver(BaseHTTPRequestHandler):
    def do_POST(self):
        if not hmac.compare_digest(self.headers.get("Authorization", "").encode(), f"Bearer {CODE}".encode()):
            self.send_error(401)
            return
        if self.path not in ("/preview", "/exchange"):
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 16 * 1024 * 1024:
                self.send_error(413)
                return
            self.connection.settimeout(4)
            body = self.rfile.read(length)
            if len(body) != length:
                raise ValueError("Incomplete body")
            value = body if self.path == "/preview" else json.loads(body)
            if self.path == "/exchange":
                if not isinstance(value, dict) or not all(
                    isinstance(value.get(key), str) for key in ("id", "prompt", "response")
                ):
                    raise ValueError("Invalid exchange")
                frames = value.get("frames")
                if not isinstance(frames, list) or not 1 <= len(frames) <= 4:
                    raise ValueError("Invalid frames")
            with lock:
                current = latest.get(self.path)
                if (self.path != "/exchange" or not current or current["id"] != value["id"]
                        or value["response"] != "Waiting for Gemini…"):
                    latest[self.path] = value
        except (ValueError, OSError):
            self.send_error(400)
            return
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_):
        pass


def main():
    hostname = subprocess.check_output(
        ["/usr/sbin/scutil", "--get", "LocalHostName"], text=True
    ).strip()
    with ThreadingHTTPServer(("0.0.0.0", PORT), Receiver) as server:
        Thread(target=server.serve_forever, daemon=True).start()
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            metadata = directory / "exchange.json"
            preview = directory / "preview.jpg"
            def refresh():
                shown = {}
                while not stopped.wait(0.1):
                    with lock:
                        updates = latest.copy()
                    for route, target in (("/preview", preview), ("/exchange", metadata)):
                        value = updates.get(route)
                        if value is None or value is shown.get(route):
                            continue
                        staging = target.with_suffix(".tmp")
                        staging.write_bytes(value if route == "/preview" else json.dumps(value).encode())
                        staging.replace(target)
                        shown[route] = value

            from threading import Event
            stopped = Event()
            worker = Thread(target=refresh)
            worker.start()
            try:
                subprocess.run(
                    ["/usr/bin/swift", "-module-cache-path", str(directory / "module-cache"), str(Path(__file__).with_name("Viewer.swift")),
                     str(directory), hostname + ".local", CODE], check=True
                )
            finally:
                stopped.set()
                worker.join()
                server.shutdown()


if __name__ == "__main__":
    main()
