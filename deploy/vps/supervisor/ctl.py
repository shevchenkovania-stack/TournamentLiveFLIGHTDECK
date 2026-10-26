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
#   GET  /labels                -> {"a":"Татами A · Кубок", ...} (operator captions)
#   POST /labels                -> body {"label":{"<screen>":"<text>"}}; merges the
#                                 caption into the labels file. The caption is a
#                                 DISPLAY name only - routing never depends on it.
#
# NUMBERED-KEY model: screen letters a..h are screens 1..8 everywhere the
# operator looks (errors, panel cards). Key N feeds screen N; the letter stays
# as the internal path name (broadcast/<letter>, outputs file).
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
LABELS_LOCK = threading.Lock()

INTENT_DIR = sys.argv[1] if len(sys.argv) > 1 else "/control"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8090
TATAMIS = [t for t in (os.environ.get("TATAMIS") or "a b c d e f g h").split()]
OUTPUTS_PATH = os.environ.get("OUTPUTS_PATH", "/outputs/outputs.local.conf")
# Operator captions ("Татами A · Кубок района") shown on each screen card.
LABELS_PATH = os.environ.get("LABELS_FILE", os.path.join(INTENT_DIR, "labels.json"))

# <letter> <dest>, where a leading '#' marks a disabled entry.
LINE_RE = re.compile(r"^\s*#?\s*([a-z])\s+(\S.*)$")

# Known platform push bases (mirror of the cockpit's PLATFORMS table). Used
# only for a human-readable platform name and one YouTube-specific check.
YT_BASE = "rtmp://a.rtmp.youtube.com/live2/"
BASE_NAMES = {
    "rtmp://ovsu.okcdn.ru/input/": "VK",
    YT_BASE: "YouTube",
}


def scr_name(t):
    """Operator-facing screen name: letter a..h -> 'ЭКРАН 1..8'."""
    if t in TATAMIS:
        return f"ЭКРАН {TATAMIS.index(t) + 1}"
    return f"ЭКРАН? {t.upper()}"


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
        return (f"{scr_name(t)} ({dest_label(dest)}): в адресе два RTMP URL подряд — "
                "в поле «ключ» нужен ТОЛЬКО stream key без rtmp://")
    if not dest.startswith(("rtmp://", "rtmps://", "srt://")):
        return f"{scr_name(t)}: адрес должен начинаться с rtmp:// (полный URL)"
    if "ВСТАВЬ" in dest:
        return (f"{scr_name(t)} ({dest_label(dest)}): это заглушка вместо ключа — "
                "вставь настоящий stream key")
    key = dest.rsplit("/", 1)[-1]
    if dest.startswith(YT_BASE) and key.rstrip("/") == "live2":
        return (f"{scr_name(t)} (YouTube): нет stream key — вставь только ключ "
                "вида xxxx-xxxx-xxxx-xxxx-xxxx, без rtmp://")
    if not key:
        return f"{scr_name(t)}: в адресе нет ключа после последнего /"
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
            errors.append(f"{scr_name(t)}: одинаковая строка площадки повторяется в списке")
            continue
        if dest:
            seen.add((t, dest))
    if errors:
        return read_outputs(), errors

    header = (
        "# Platform destinations - managed from the web panel (Cockpit).\n"
        "# Format: <screen letter a..h = screens 1..8> <full rtmp url with key>.\n"
        "# A '#' line = disabled. Several lines may share one letter (many platforms).\n"
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


def read_labels():
    """Operator captions per screen; missing file -> empty map."""
    try:
        with open(LABELS_PATH, encoding="utf-8-sig") as f:
            data = json.load(f)
        return {k: v for k, v in data.items() if k in TATAMIS and isinstance(v, str)}
    except (OSError, ValueError):
        return {}


def write_labels(patch):
    """Merge {screen: caption} into the labels file. Returns (labels, errors)."""
    errors = []
    for t, v in patch.items():
        if t not in TATAMIS:
            errors.append(f"неизвестный экран {t!r}")
        elif not isinstance(v, str) or len(v) > 120:
            errors.append(f"{scr_name(t)}: подпись должна быть текстом до 120 символов")
    if errors:
        return read_labels(), errors
    labels = read_labels()
    labels.update({t: v.strip() for t, v in patch.items()})
    tmp = f"{LABELS_PATH}.tmp.{os.getpid()}.{time.time_ns()}"
    with LABELS_LOCK:
        os.makedirs(os.path.dirname(LABELS_PATH) or ".", exist_ok=True)
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(labels, f, ensure_ascii=False)
            os.replace(tmp, LABELS_PATH)
        finally:
            try:
                if os.path.exists(tmp):
                    os.remove(tmp)
            except OSError:
                pass
    return read_labels(), []


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
        elif p == ["labels"]:
            self._send(200, read_labels())
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
        elif p == ["labels"]:
            body = self._read_body()
            patch = body.get("label")
            if not isinstance(patch, dict):
                self._send(400, {"error": "expected {'label':{screen:text,...}}"}); return
            saved, errors = write_labels(patch)
            if errors:
                self._send(400, {"error": "invalid labels", "errors": errors})
            else:
                self._send(200, saved)
        else:
            self._send(400, {"error": "use /end/<screen>, /resume/<screen>, /outputs or /labels"})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
