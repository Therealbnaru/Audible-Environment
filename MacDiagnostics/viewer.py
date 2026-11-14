"""Live Mac diagnostics for Audible Environment."""
import base64
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import secrets
import subprocess
import tempfile
from threading import Lock, Thread
import tkinter as tk
from tkinter import ttk
from tkinter.scrolledtext import ScrolledText

PORT = 8766
CODE = secrets.token_urlsafe(12)
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


def thumbnail(data, directory, size):
    source = directory / "frame.jpg"
    target = directory / "frame.png"
    source.write_bytes(data)
    subprocess.run(["/usr/bin/sips", "-s", "format", "png", "-Z", str(size),
                    str(source), "--out", str(target)],
                   check=True, capture_output=True, timeout=2)
    return tk.PhotoImage(file=str(target))


def main():
    root = tk.Tk()
    root.title("Audible Environment Live Diagnostics")
    root.geometry("1100x800")
    hostname = subprocess.check_output(["/usr/sbin/scutil", "--get", "LocalHostName"], text=True).strip()
    connection = ttk.Entry(root, width=72)
    connection.insert(0, f"Mac hostname: {hostname}.local    Viewer code: {CODE}")
    connection.configure(state="readonly")
    connection.pack(pady=8)
    feed = ttk.LabelFrame(root, text="Live glasses view")
    feed.pack(fill="x", padx=12, pady=4)
    image_label = ttk.Label(feed, text="Waiting for glasses frames…")
    image_label.pack(pady=4)
    sent = ttk.LabelFrame(root, text="Frames sent to Gemini")
    sent.pack(fill="x", padx=12, pady=4)
    details = ScrolledText(root, wrap="word", state="disabled", height=12)
    details.pack(fill="both", expand=True, padx=12, pady=8)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Receiver)
    Thread(target=server.serve_forever, daemon=True).start()
    shown = {}
    displayed_id = None

    with tempfile.TemporaryDirectory() as temp:
        directory = Path(temp)

        def refresh():
            nonlocal displayed_id
            with lock:
                updates = latest.copy()
            try:
                preview = updates.get("/preview")
                if preview is not None and preview is not shown.get("/preview"):
                    shown["/preview"] = preview
                    image_label.image = thumbnail(preview, directory, 460)
                    image_label.configure(image=image_label.image, text="")
                exchange = updates.get("/exchange")
                if exchange is not None and exchange is not shown.get("/exchange"):
                    shown["/exchange"] = exchange
                    if displayed_id != exchange["id"]:
                        images = [thumbnail(base64.b64decode(frame, validate=True), directory, 220)
                                  for frame in exchange["frames"]]
                        for child in sent.winfo_children():
                            child.destroy()
                        for index, image in enumerate(images, 1):
                            label = ttk.Label(sent, text=f"Frame {index}", image=image, compound="top")
                            label.image = image
                            label.pack(side="left", padx=5, pady=4)
                        displayed_id = exchange["id"]
                    details.configure(state="normal")
                    details.delete("1.0", "end")
                    details.insert("1.0", f'PROMPT\n{exchange["prompt"]}\n\nGEMINI\n{exchange["response"]}')
                    details.configure(state="disabled")
            except (OSError, ValueError, TypeError, subprocess.SubprocessError, tk.TclError):
                pass
            root.after(100, refresh)

        refresh()
        try:
            root.mainloop()
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
