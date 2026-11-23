"""A stand-in for the Windows companion, for testing the iPhone app in the simulator (macOS CI).

It speaks the same protocol on port 47821 (PIN 123456), carries nothing out, and records every action it
receives. A small HTTP server on port 47822 lets the UI tests read that record:

  GET  /log        every action received, in order, as a JSON list
  GET  /stats      {"mic_bytes": n, "speaker_bytes": n, "connected": n, "files": n}
  POST /reset      clears the log and the counters
  GET  /audio/<f>  serves a test recording (WAV) from the folder given with --audio

It answers "getclip" with "Text from the computer", lists one file (hello.txt) in the shared folder,
streams a 440 Hz tone as the computer's sound while the speaker is on, and counts microphone audio.
"""
import argparse
import http.server
import json
import math
import os
import socket
import struct
import threading
import time

PIN = "123456"
TOKEN = "mock-token-for-tests"
FILE_BODY = b"Hello from the computer.\n" * 40

lock = threading.Lock()
log = []
stats = {"mic_bytes": 0, "speaker_bytes": 0, "connected": 0, "files": 0}


def record(action):
    with lock:
        log.append(action)
    print("ACTION", json.dumps(action, ensure_ascii=False), flush=True)


def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


class Session:
    def __init__(self, sock):
        self.sock = sock
        self.wlock = threading.Lock()
        self.speaker_on = False
        self.upload = None

    def send(self, kind, payload):
        with self.wlock:
            self.sock.sendall(struct.pack(">BI", kind, len(payload)) + payload)

    def send_json(self, obj):
        self.send(1, json.dumps(obj).encode("utf-8"))

    def speaker_loop(self):
        rate, phase = 48000, 0.0
        frames = rate // 50
        while self.speaker_on:
            data = bytearray()
            for _ in range(frames):
                v = 0.2 * math.sin(phase)
                phase += 2 * math.pi * 440 / rate
                data += struct.pack("<ff", v, v)
            try:
                self.send(3, bytes(data))
            except OSError:
                return
            with lock:
                stats["speaker_bytes"] += len(data)
            time.sleep(0.02)

    def do(self, a, reply):
        record(a)
        t = a.get("t")
        if t == "getclip":
            reply["clip"] = "Text from the computer"
        elif t == "speaker":
            if a.get("on") and not self.speaker_on:
                self.speaker_on = True
                self.send_json({"speaker": {"rate": 48000, "channels": 2}})
                threading.Thread(target=self.speaker_loop, daemon=True).start()
            elif not a.get("on"):
                self.speaker_on = False
        elif t == "mic":
            if a.get("on"):
                reply["device"] = "CABLE Input (mock)"
        elif t == "ls":
            reply["listing"] = {"root": "Downloads\\WiFiTalk", "path": "", "parent": None, "entries": [
                {"name": "hello.txt", "path": "hello.txt", "is_dir": False, "size": len(FILE_BODY), "modified": time.time()}]}
        elif t == "get":
            for i in range(0, len(FILE_BODY), 256):
                self.send(4, FILE_BODY[i:i + 256])
        elif t == "put":
            self.upload = bytearray()
        elif t == "putend":
            reply["file"] = {"name": a.get("s", "file"), "path": "file", "size": len(self.upload or b"")}
            with lock:
                stats["files"] += 1
        elif t not in ("text", "keys", "move", "click", "down", "up", "scroll", "wait", "open", "clip", "power", "ping"):
            raise ValueError("unknown action: %s" % t)

    def run(self):
        authed = False
        try:
            while True:
                kind, length = struct.unpack(">BI", read_exact(self.sock, 5))
                payload = read_exact(self.sock, length)
                if kind == 2:
                    with lock:
                        stats["mic_bytes"] += len(payload)
                    continue
                if kind == 4:
                    if self.upload is not None:
                        self.upload += payload
                    continue
                msg = json.loads(payload)
                if not authed:
                    hello = msg.get("hello") or {}
                    if hello.get("pin") == PIN or hello.get("token") == TOKEN:
                        authed = True
                        with lock:
                            stats["connected"] += 1
                        record({"t": "hello", "with": "pin" if "pin" in hello else "token"})
                        self.send_json({"welcome": {"token": TOKEN, "name": "TEST-PC", "mic": True, "version": 1}})
                    else:
                        self.send_json({"error": "wrong_pin"})
                        return
                    continue
                reply = {"done": msg.get("id"), "ok": True}
                try:
                    for a in msg.get("do", []):
                        self.do(a, reply)
                except Exception as e:  # noqa: BLE001
                    reply = {"done": msg.get("id"), "ok": False, "error": str(e)}
                if msg.get("q") and reply["ok"]:
                    continue
                self.send_json(reply)
        except (EOFError, OSError):
            pass
        finally:
            self.speaker_on = False
            self.sock.close()


def serve_companion():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", 47821))
    srv.listen()
    while True:
        conn, _ = srv.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        threading.Thread(target=Session(conn).run, daemon=True).start()


def make_http(audio_dir):
    class H(http.server.BaseHTTPRequestHandler):
        def _send(self, code, body, ctype="application/json"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/log":
                with lock:
                    self._send(200, json.dumps(log, ensure_ascii=False).encode("utf-8"))
            elif self.path == "/stats":
                with lock:
                    self._send(200, json.dumps(stats).encode())
            elif self.path.startswith("/audio/") and audio_dir:
                path = os.path.join(audio_dir, os.path.basename(self.path))
                if os.path.exists(path):
                    self._send(200, open(path, "rb").read(), "audio/wav")
                else:
                    self._send(404, b"{}")
            else:
                self._send(404, b"{}")

        def do_POST(self):
            if self.path == "/reset":
                with lock:
                    log.clear()
                    for k in stats:
                        stats[k] = 0
                self._send(200, b"{}")
            else:
                self._send(404, b"{}")

        def log_message(self, *args):
            pass

    return H


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--audio", default="")
    args = p.parse_args()
    threading.Thread(target=serve_companion, daemon=True).start()
    print("mock companion on 47821, test API on 47822", flush=True)
    http.server.ThreadingHTTPServer(("127.0.0.1", 47822), make_http(args.audio)).serve_forever()
