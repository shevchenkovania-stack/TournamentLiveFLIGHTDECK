#!/usr/bin/env python3
# Tiny control server for the supervisor (stdlib only).
# The cockpit panel calls these endpoints; we persist operator intent and manage
# the platform output destinations (VK/YouTube keys) as plain files.
#
#   GET  /state                 -> {"a":"hold", "b":"ended", ...}
#   POST /end/<tatami>          -> graceful end: stop feeding broadcast/<x> (platform ends)
#   POST /resume/<tatami>       -> back to hold: live if input up, else fallback
#   GET  /outputs               -> {"items":[{"tatami","dest","enabled"}, ...]}
#   POST /outputs               -> body {"items":[...]}; rewrites the outputs file
#
# Outputs file format (one entry per line), read by the relayer container:
#   <letter> <full-rtmp-url-with-key>        (enabled)
#   #<letter> <full-rtmp-url-with-key>       (disabled)
#
# No auth here: it is reached only through the panel origin, which on the VPS is
# already behind Caddy TLS + BasicAuth.
import sys, os, json, re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

INTENT_DIR = sys.argv[1] if len(sys.argv) > 1 else "/control"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8090
TATAMIS = [t for t in (os.environ.get("TATAMIS") or "a b c d e f g h").split()]
OUTPUTS_PATH = os.environ.get("OUTPUTS_PATH", "/outputs/outputs.local.conf")

# <letter> <dest>, where a leading '#' marks a disabled entry.
LINE_RE = re.compile(r"^\s*#?\s*([a-z])\s+(\S.*)$")


def intent_of(t):
    try:
        with open(os.path.join(INTENT_DIR, t)) as f:
            return (f.read().strip() or "hold")
    except OSError:
        return "hold"


def set_intent(t, v):
    os.makedirs(INTENT_DIR, exist_ok=True)
    with open(os.path.join(INTENT_DIR, t), "w") as f:
        f.write(v + "\n")


def read_outputs():
    """Parse the outputs file into per-tatami entries; unknown tatamis are hidden."""
    entries = {}
    try:
        with open(OUTPUTS_PATH, encoding="utf-8") as f:
            for raw in f:
                line = raw.rstrip("\r\n")
                if not line.strip():
                    continue
                m = LINE_RE.match(line)
                if not m:
                    continue  # header/comment we don't own
                t, dest = m.group(1), m.group(2).strip()
                entries[t] = {"tatami": t, "dest": dest,
                              "enabled": not line.lstrip().startswith("#")}
    except OSError:
        pass
    # Stable order: all known tatamis first, then any extras from the file.
    ordered = [entries[t] if t in entries else {"tatami": t, "dest": "", "enabled": False}
               for t in TATAMIS]
    for t, e in entries.items():
        if t not in TATAMIS:
            ordered.append(e)
    return ordered


def write_outputs(items):
    """Persist the panel's list back to the outputs file (atomic replace)."""
    header = (
        "# Platform destinations - managed from the web panel (Cockpit).\n"
        "# Format: <tatami letter> <full rtmp url with key>. A '#' line = disabled.\n"
        "# THIS FILE HOLDS LIVE KEYS - it is gitignored; do not commit.\n"
    )
    lines = [header]
    for it in items:
        t = (it.get("tatami") or "").strip().lower()
        dest = (it.get("dest") or "").strip()
        enabled = bool(it.get("enabled"))
        if t not in TATAMIS or not dest:
            continue  # skip empty/unknown rows so the file stays clean
        lines.append(f"{t} {dest}\n" if enabled else f"#{t} {dest}\n")
    tmp = OUTPUTS_PATH + ".tmp"
    os.makedirs(os.path.dirname(OUTPUTS_PATH), exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as f:
        f.writelines(lines)
    os.replace(tmp, OUTPUTS_PATH)
    return read_outputs()


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _parts(self):
        return [p for p in self.path.split("?")[0].split("/") if p]

    def _read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode())
        except (ValueError, UnicodeDecodeError):
            return {}

    def do_GET(self):
        p = self._parts()
        if p == ["state"]:
            self._send(200, {t: intent_of(t) for t in TATAMIS})
        elif p == ["outputs"]:
            self._send(200, {"items": read_outputs()})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        p = self._parts()
        if len(p) == 2 and p[0] in ("end", "resume") and p[1] in TATAMIS:
            set_intent(p[1], "ended" if p[0] == "end" else "hold")
            self._send(200, {"tatami": p[1], "intent": intent_of(p[1])})
        elif p == ["outputs"]:
            body = self._read_body()
            items = body.get("items")
            if not isinstance(items, list):
                self._send(400, {"error": "expected {'items':[...]}"}); return
            self._send(200, {"items": write_outputs(items)})
        else:
            self._send(400, {"error": "use /end/<tatami>, /resume/<tatami> or /outputs"})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
