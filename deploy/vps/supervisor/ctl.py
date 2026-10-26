#!/usr/bin/env python3
# Tiny control server for the supervisor (stdlib only).
# The cockpit panel calls these endpoints; we persist operator intent and manage
# the platform output destinations (VK/YouTube keys) as plain files.
#
#   GET  /state                 -> {"a":"hold", "b":"ended", ...}
#   POST /end/<tatami>          -> graceful end: stop feeding broadcast/<x> (platform ends)
#   POST /resume/<tatami>       -> back to hold: live if input up, else fallback
#   GET  /outputs               -> {"items":[{"tatami","dest","enabled"}, ...]}
#   POST /outputs               -> body {"items":[...]}; rewrites the outputs file.
#                                 Items are validated server-side: any bad dest
#                                 (doubled URL, spaces, missing key) rejects the
#                                 WHOLE save with {"errors":[...]}, so a broken
#                                 key can never silently reach the relayer.
#   GET  /routes                -> {"routes":{"a":"auto",...}, "resolved":{"a":"c",...}}
#   POST /routes                -> body {"routes":{"<screen>":"<letter>|auto",...}};
#                                 decouples a screen (broadcast/<x>) from its source
#                                 tatami. 'auto' takes any free online input.
#                                 'resolved' is what the supervisor actually assigned.
#
# Outputs file format (one entry per line), read by the relayer container:
#   <letter> <full-rtmp-url-with-key>        (enabled)
#   #<letter> <full-rtmp-url-with-key>       (disabled)
# Several lines may share one letter (same broadcast -> many platforms).
#
# No auth here: it is reached only through the panel origin, which on the VPS is
# already behind Caddy TLS + BasicAuth.

import sys, os, json, re, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ThreadingHTTPServer handles concurrent POSTs in parallel; serialize outputs
# file rewrites (lock) and give each writer its own tmp file, so two saves
# (double-click, panel + manual) can never interleave into a corrupted file.
OUTPUTS_LOCK = threading.Lock()
ROUTES_LOCK = threading.Lock()

INTENT_DIR = sys.argv[1] if len(sys.argv) > 1 else "/control"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8090
TATAMIS = [t for t in (os.environ.get("TATAMIS") or "a b c d e f g h").split()]
OUTPUTS_PATH = os.environ.get("OUTPUTS_PATH", "/outputs/outputs.local.conf")
# Screen->source routing table (we write it; the supervisor reads it every loop)
# and the resolved assignment the supervisor publishes for display.
ROUTES_PATH = os.environ.get("ROUTES_FILE", os.path.join(INTENT_DIR, "routes.conf"))
RESOLVED_PATH = os.environ.get("RESOLVED_FILE", os.path.join(INTENT_DIR, "routes.resolved"))

# <letter> <dest>, where a leading '#' marks a disabled entry.
LINE_RE = re.compile(r"^\s*#?\s*([a-z])\s+(\S.*)$")

# Known platform push bases (mirror of the cockpit's PLATFORMS table). Used
# only for a human-readable platform name and one YouTube-specific check.
YT_BASE = "rtmp://a.rtmp.youtube.com/live2/"
BASE_NAMES = {
    "rtmp://ovsu.okcdn.ru/input/": "VK",
    YT_BASE: "YouTube",
}


def dest_label(dest):
    """Short platform name for an error message (VK/YouTube/настроено)."""
    for base, name in BASE_NAMES.items():
        if dest.startswith(base):
            return name
    return "площадка"


def validate_dest(t, dest):
    """Return an error string for a panel entry, or None if it looks usable.

    Guards the classic operator mistake: pasting the FULL server URL into the
    stream-key field, which used to save as rtmp://host/app/rtmp://host/app and
    silently broke the relay.
    """
    if not dest:
        return None  # empty row: skipped on write
    if dest.count("://") > 1 or " " in dest or "\t" in dest:
        return (f"TATAMI {t.upper()} ({dest_label(dest)}): в адресе два RTMP URL подряд — "
                "в поле «ключ» нужен ТОЛЬКО stream key без rtmp://")
    if not dest.startswith(("rtmp://", "rtmps://", "srt://")):
        return f"TATAMI {t.upper()}: адрес должен начинаться с rtmp:// (полный URL)"
    if "ВСТАВЬ" in dest:
        return (f"TATAMI {t.upper()} ({dest_label(dest)}): это заглушка вместо ключа — "
                "вставь настоящий stream key")
    key = dest.rsplit("/", 1)[-1]
    if dest.startswith(YT_BASE) and key.rstrip("/") == "live2":
        return ("TATAMI " + t.upper() + " (YouTube): нет stream key — вставь только ключ "
                "вида xxxx-xxxx-xxxx-xxxx-xxxx, без rtmp://")
    if not key:
        return f"TATAMI {t.upper()}: в адресе нет ключа после последнего /"
    return None


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
    """Parse the outputs file into an ordered list of entries.

    One letter may have SEVERAL platforms (several lines) - all are kept.
    Entries for unknown letters are preserved too so nothing is lost if the
    panel re-saves; the cockpit renders only known tatamis.
    """
    entries = []
    try:
        # utf-8-sig: tolerate a Windows/Notepad BOM, otherwise it glues onto
        # the first line and an entry on line 1 would silently not parse.
        with open(OUTPUTS_PATH, encoding="utf-8-sig") as f:
            for raw in f:
                line = raw.rstrip("\r\n")
                if not line.strip():
                    continue
                m = LINE_RE.match(line)
                if not m:
                    continue  # header/comment we don't own
                t, dest = m.group(1), m.group(2).strip()
                entries.append({"tatami": t, "dest": dest,
                                "enabled": not line.lstrip().startswith("#")})
    except OSError:
        pass
    return entries


def write_outputs(items):
    """Validate then persist the panel's list back to the outputs file.

    Returns (entries, errors). If ANY item is invalid nothing is written - the
    caller answers 400 with the error list so the operator sees the problem
    instead of pushing a broken key to a live platform.
    """
    errors = []
    seen = set()
    for it in items:
        t = (it.get("tatami") or "").strip().lower()
        dest = (it.get("dest") or "").strip()
        if not it.get("enabled"):
            continue  # disabled rows never reach the relayer - don't block on them
        err = validate_dest(t, dest)
        if err:
            errors.append(err)
            continue
        if dest and (t, dest) in seen:
            errors.append(f"TATAMI {t.upper()}: одинаковая строка площадки повторяется в списке")
            continue
        if dest:
            seen.add((t, dest))
    if errors:
        return read_outputs(), errors

    header = (
        "# Platform destinations - managed from the web panel (Cockpit).\n"
        "# Format: <tatami letter> <full rtmp url with key>. A '#' line = disabled.\n"
        "# Several lines may share one letter (VK + YouTube on the same tatami).\n"
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
    # Unique tmp name per writer + process: never clash even under concurrency.
    tmp = f"{OUTPUTS_PATH}.tmp.{os.getpid()}.{threading.get_ident()}.{time.time_ns()}"
    with OUTPUTS_LOCK:
        os.makedirs(os.path.dirname(OUTPUTS_PATH), exist_ok=True)
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                f.writelines(lines)
            # Atomic publish: readers see old or new file, never a partial one.
            # Win32 raises PermissionError (sharing violation) when a reader
            # (AV / Docker file-share) holds the target mid-rename; retry with
            # backoff. On Linux os.replace never fails, so the loop is free.
            for attempt in range(10):
                try:
                    os.replace(tmp, OUTPUTS_PATH)
                    break
                except PermissionError:
                    if attempt == 9:
                        raise
                    time.sleep(0.05 * (attempt + 1))
        finally:
            try:
                if os.path.exists(tmp):
                    os.remove(tmp)
            except OSError:
                pass
    return read_outputs(), []


ROUTE_LINE_RE = re.compile(r"^\s*([a-z])\s*=\s*([a-z]*)\s*$")


def read_routes():
    """Configured screen->source map; every screen present, default 'auto'."""
    routes = {t: "auto" for t in TATAMIS}
    try:
        with open(ROUTES_PATH, encoding="utf-8-sig") as f:
            for raw in f:
                m = ROUTE_LINE_RE.match(raw)
                if m and m.group(1) in routes:
                    routes[m.group(1)] = m.group(2) or "auto"
    except OSError:
        pass
    return routes


def read_resolved():
    """What the supervisor actually assigned this loop (empty source -> None)."""
    res = {}
    try:
        with open(RESOLVED_PATH, encoding="utf-8-sig") as f:
            for raw in f:
                m = ROUTE_LINE_RE.match(raw)
                if m:
                    res[m.group(1)] = m.group(2) or None
    except OSError:
        pass
    return res


def write_routes(routes):
    """Validate + persist the screen->source map. Returns (routes, errors)."""
    errors = []
    clean = {}
    for t, src in routes.items():
        t = (t or "").strip().lower()
        src = (src or "auto").strip().lower()
        if t not in TATAMIS:
            errors.append(f"неизвестный экран {t!r}")
            continue
        if src != "auto" and src not in TATAMIS:
            errors.append(f"ЭКРАН {t.upper()}: источник должен быть буквой татами или auto")
            continue
        clean[t] = src
    if errors:
        return read_routes(), errors
    header = (
        "# Screen -> source routing, managed from the Flight Deck.\n"
        "# <screen>=<tatami letter> pins the input; <screen>=auto takes any free one.\n"
        "# Read by the supervisor every loop; safe to edit by hand.\n"
    )
    lines = [header] + [f"{t}={clean.get(t, 'auto')}\n" for t in TATAMIS]
    tmp = f"{ROUTES_PATH}.tmp.{os.getpid()}.{time.time_ns()}"
    with ROUTES_LOCK:
        os.makedirs(os.path.dirname(ROUTES_PATH) or ".", exist_ok=True)
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                f.writelines(lines)
            os.replace(tmp, ROUTES_PATH)
        finally:
            try:
                if os.path.exists(tmp):
                    os.remove(tmp)
            except OSError:
                pass
    return read_routes(), []


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
        elif p == ["routes"]:
            self._send(200, {"routes": read_routes(), "resolved": read_resolved()})
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
            entries, errors = write_outputs(items)
            if errors:
                self._send(400, {"error": "invalid outputs", "errors": errors})
            else:
                self._send(200, {"items": entries, "errors": []})
        elif p == ["routes"]:
            body = self._read_body()
            routes = body.get("routes")
            if not isinstance(routes, dict):
                self._send(400, {"error": "expected {'routes':{screen:src,...}}"}); return
            saved, errors = write_routes(routes)
            if errors:
                self._send(400, {"error": "invalid routes", "errors": errors})
            else:
                self._send(200, {"routes": saved, "resolved": read_resolved()})
        else:
            self._send(400, {"error": "use /end/<tatami>, /resume/<tatami>, /outputs or /routes"})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
