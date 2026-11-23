"""Checks a running WiFiTalk.exe over the local network protocol, with harmless actions only.

Run WiFiTalk.exe first, then:  python windows/test_companion.py [address]
It pairs with the PIN from %APPDATA%\\WiFiTalk\\settings.txt, checks a wrong PIN is refused, sets and reads
the clipboard, sends a ping and an unknown action, and listens to the computer sound for two seconds.
"""
import json
import os
import socket
import struct
import sys
import time

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = 47821


def settings_pin():
    path = os.path.join(os.environ["APPDATA"], "WiFiTalk", "settings.txt")
    for line in open(path, encoding="utf-8"):
        if line.startswith("pin="):
            return line[4:].strip()
    raise SystemExit("no PIN in " + path)


def send(sock, kind, payload):
    sock.sendall(struct.pack(">BI", kind, len(payload)) + payload)


def send_json(sock, obj):
    send(sock, 1, json.dumps(obj).encode("utf-8"))


def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("closed")
        buf += chunk
    return buf


def read_frame(sock):
    kind, length = struct.unpack(">BI", read_exact(sock, 5))
    return kind, read_exact(sock, length)


def read_json(sock):
    while True:
        kind, payload = read_frame(sock)
        if kind == 1:
            return json.loads(payload)


def connect():
    s = socket.create_connection((HOST, PORT), timeout=10)
    return s


# A CI machine may have no sound device or clipboard; there these two checks are reported, not failed.
CI = bool(os.environ.get("CI"))


def check(name, ok, optional=False):
    if not ok and optional and CI:
        print("SKIP " + name + " (not available on this CI machine)")
        return
    print(("PASS " if ok else "FAIL ") + name)
    if not ok:
        check.failed = True


check.failed = False

# a wrong PIN is refused and the connection closed
s = connect()
send_json(s, {"hello": {"pin": "000000" if settings_pin() != "000000" else "111111"}})
check("wrong PIN refused", read_json(s).get("error") == "wrong_pin")
s.close()

# pairing with the right PIN gives a token
s = connect()
send_json(s, {"hello": {"pin": settings_pin()}})
welcome = read_json(s).get("welcome") or {}
token = welcome.get("token", "")
check("paired with PIN, token received", len(token) > 20)
s.close()

# the token alone reconnects
s = connect()
send_json(s, {"hello": {"token": token}})
check("reconnected with token", "welcome" in read_json(s))

text = "WiFiTalk test ✓ اختبار"
send_json(s, {"id": 1, "do": [{"t": "getclip"}]})
old_clip = read_json(s).get("clip", "")
send_json(s, {"id": 2, "do": [{"t": "clip", "s": text}, {"t": "getclip"}]})
r = read_json(s)
check("clipboard set and read back (Arabic too)", r.get("done") == 2 and r.get("clip") == text, optional=True)
send_json(s, {"id": 3, "do": [{"t": "clip", "s": old_clip}]})
read_json(s)

send_json(s, {"id": 4, "do": [{"t": "ping"}]})
check("ping", read_json(s).get("ok") is True)

send_json(s, {"id": 5, "do": [{"t": "format-disk"}]})
r = read_json(s)
check("unknown action refused", r.get("ok") is False and "unknown action" in r.get("error", ""))

# the shared folder: send a file, list it, fetch it back, and refuse a path that climbs out
name = "wifitalk-test-%d.txt" % int(time.time())
body = ("WiFiTalk ✓ ملف\n" * 5000).encode("utf-8")
send_json(s, {"id": 10, "do": [{"t": "put", "s": name}]})
read_json(s)
for i in range(0, len(body), 100000):
    send(s, 4, body[i:i + 100000])
send_json(s, {"id": 11, "do": [{"t": "putend"}]})
saved = (read_json(s).get("file") or {})
check("file sent to the computer", saved.get("size") == len(body))
send_json(s, {"id": 12, "do": [{"t": "ls", "s": ""}]})
listing = read_json(s).get("listing") or {}
check("shared folder lists it", any(e.get("name") == saved.get("name") for e in listing.get("entries", [])))
send_json(s, {"id": 13, "do": [{"t": "get", "s": saved.get("path", "")}]})
got = b""
while True:
    kind, payload = read_frame(s)
    if kind == 4:
        got += payload
    elif kind == 1 and json.loads(payload).get("done") == 13:
        break
check("file fetched back unchanged", got == body)
send_json(s, {"id": 14, "do": [{"t": "get", "s": "../../Windows/win.ini"}]})
r = read_json(s)
check("path outside the shared folder refused", r.get("ok") is False)
try:
    os.remove(os.path.join(os.environ["USERPROFILE"], "Downloads", "WiFiTalk", saved.get("name", "")))
except OSError:
    pass

# computer sound: announced rate, then audio frames while something plays (silence sends nothing)
send_json(s, {"id": 6, "do": [{"t": "speaker", "on": True}]})
rate, audio, end = None, 0, time.time() + 2
s.settimeout(0.5)
while time.time() < end:
    try:
        kind, payload = read_frame(s)
    except socket.timeout:
        continue
    if kind == 1:
        msg = json.loads(payload)
        rate = (msg.get("speaker") or {}).get("rate", rate)
    elif kind == 3:
        audio += len(payload)
check("computer sound announced (rate %s, %d bytes in 2 s)" % (rate, audio), rate in (44100, 48000, 96000, 192000), optional=True)
send_json(s, {"id": 7, "do": [{"t": "speaker", "on": False}]})
s.close()

print("virtual cable for the microphone:", welcome.get("mic"))
sys.exit(1 if check.failed else 0)
