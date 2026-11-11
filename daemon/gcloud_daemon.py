"""Google 粵語雲端候選 — background fetcher for Rime (小狼毫).

The Rime Lua plugin (lua/gcloud.lua) cannot make network calls, so it talks to
this daemon through small files under %APPDATA%\\Rime\\gcloud:

  request.txt     Lua writes "<query>\\n<seq>\\n<push 0|1>\\n<engine>\\n" when it wants a lookup.
                  An empty query is a "user is typing" ping: no text is sent anywhere, the
                  daemon only keeps its HTTPS connections to Google warm.
  cache\\q_<query>.txt (engine "jyutping") or cache\\q_<engine>_<query>.txt
                  daemon writes "OK\\n" + "<matched_len>\\t<text>\\t<annotation>" lines,
                  or "ERR\\t<message>" when the lookup failed.
  heartbeat.txt   epoch seconds, refreshed every 2 s so Lua knows we are alive.

Run with pythonw.exe so no console window appears. Standard library only.

  python gcloud_daemon.py            run the daemon
  python gcloud_daemon.py --once Q   fetch one query, print it, exit
  python gcloud_daemon.py --verbose  also log each query text (privacy: off by default)
"""

import ctypes
import http.client
import json
import logging
import logging.handlers
import os
import ssl
import sys
import threading
import time
import urllib.parse
from collections import deque

APP_DIR = os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"), "Rime", "gcloud")
CACHE_DIR = os.path.join(APP_DIR, "cache")
REQUEST_FILE = os.path.join(APP_DIR, "request.txt")
HEARTBEAT_FILE = os.path.join(APP_DIR, "heartbeat.txt")
LOG_FILE = os.path.join(APP_DIR, "daemon.log")

HOST = "inputtools.google.com"
# Google Input Tools has two Cantonese engines:
#   「粵拼」 yue-hant-t-i0-jyutping  Jyutping (jat = 日, z = 咗) — matches the jyut6ping3 schema
#   「粵語」 yue-hant-t-i0-und       Yale-based (j = Jyutping z, so jat -> 則/質)
# Each Rime schema names its engine set (gcloud/engine), sent as line 4 of request.txt:
#   jyutping  Jyutping first; Yale-based only when Jyutping returns nothing (e.g. "sjfm")
#   yale      Yale-based only: it also understands Yale tone "h" (yahtbun -> 日本), while
#             the Jyutping engine would misread Yale j/ch (jau -> 有 instead of 走)
ENGINES = {
    "jyutping": ("yue-hant-t-i0-jyutping", "yue-hant-t-i0-und"),
    "yale": ("yue-hant-t-i0-und",),
}
DEFAULT_ENGINE = "jyutping"
ITC_PRIMARY = ENGINES[DEFAULT_ENGINE][0]
CACHE_VERSION = "2-jyutping+und-fallback"  # bump to clear cached results after engine changes
CACHE_VERSION_FILE = os.path.join(APP_DIR, "cache_version.txt")
NUM_CANDIDATES = 15
# Adaptive polling of request.txt: fast while typing, slow when idle (saves battery).
POLL_ACTIVE_SECONDS = 0.02    # within ACTIVE_WINDOW of the last request (~1.5% CPU)
POLL_WARM_SECONDS = 0.06      # within WARM_WINDOW
POLL_IDLE_SECONDS = 0.25
ACTIVE_WINDOW_SECONDS = 5
WARM_WINDOW_SECONDS = 60
WORKERS = 3
MAX_PENDING = 4  # stale prefixes beyond this are dropped while typing fast
MAX_QUERY_LEN = 60
ERR_RETRY_SECONDS = 5.0
MAX_CACHE_FILES = 30000
PRUNE_EVERY_SECONDS = 3600
HEARTBEAT_EVERY_SECONDS = 2.0
KEEPALIVE_SECONDS = 45  # refresh idle sockets before Google closes them ...
KEEPALIVE_WHILE_ACTIVE_SECONDS = 600  # ... but only within 10 min of real typing
HTTP_TIMEOUT_SECONDS = 6

PUSH_MAX_AGE_SECONDS = 3.0  # only nudge Rime if the result is for a request this recent

log = logging.getLogger("gcloud")
VERBOSE = False


# ---------------------------------------------------------------- refresh nudge
# cloud_first mode: when Google's answer for the *current* input arrives, send an F24
# key press. Weasel hands it to Rime, gcloud.lua swallows it while composing and
# refreshes the candidate menu, so the cloud candidates appear without another key.
# Outside a composition F24 reaches the focused app, where it normally does nothing.

if os.name == "nt":
    from ctypes import wintypes

    class _KEYBDINPUT(ctypes.Structure):
        _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                    ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]

    class _MOUSEINPUT(ctypes.Structure):
        _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD),
                    ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]

    class _HARDWAREINPUT(ctypes.Structure):
        _fields_ = [("uMsg", wintypes.DWORD), ("wParamL", wintypes.WORD), ("wParamH", wintypes.WORD)]

    class _INPUTUNION(ctypes.Union):
        _fields_ = [("mi", _MOUSEINPUT), ("ki", _KEYBDINPUT), ("hi", _HARDWAREINPUT)]

    class _INPUT(ctypes.Structure):
        _fields_ = [("type", wintypes.DWORD), ("u", _INPUTUNION)]

    _SendInput = ctypes.windll.user32.SendInput
    _SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(_INPUT), ctypes.c_int]
    _SendInput.restype = wintypes.UINT

VK_F24 = 0x87


def send_refresh_key() -> bool:
    if os.name != "nt":
        return False
    events = (_INPUT * 2)()
    for i, flags in enumerate((0, 0x0002)):  # key down, KEYEVENTF_KEYUP
        events[i].type = 1  # INPUT_KEYBOARD
        events[i].u.ki = _KEYBDINPUT(VK_F24, 0, flags, 0, 0)
    return _SendInput(2, events, ctypes.sizeof(_INPUT)) == 2


def cache_path(q: str, engine: str = DEFAULT_ENGINE) -> str:
    # "q_" prefix avoids Windows reserved names such as con / nul / aux. Queries are
    # letters only, so "q_<engine>_<q>" cannot collide with a Jyutping "q_<q>" entry.
    if engine == DEFAULT_ENGINE:
        return os.path.join(CACHE_DIR, "q_" + q + ".txt")
    return os.path.join(CACHE_DIR, "q_" + engine + "_" + q + ".txt")


def valid_query(q: str) -> bool:
    return 0 < len(q) <= MAX_QUERY_LEN and q.isascii() and q.isalpha() and q.islower()


# ---------------------------------------------------------------- fetching

_local = threading.local()


def _connection() -> http.client.HTTPSConnection:
    conn = getattr(_local, "conn", None)
    if conn is None:
        conn = http.client.HTTPSConnection(HOST, timeout=HTTP_TIMEOUT_SECONDS, context=ssl.create_default_context())
        _local.conn = conn
    return conn


def _drop_connection() -> None:
    conn = getattr(_local, "conn", None)
    if conn is not None:
        try:
            conn.close()
        except Exception:
            pass
    _local.conn = None


def parse_response(body: bytes, q: str):
    data = json.loads(body.decode("utf-8"))
    if not data or data[0] != "SUCCESS":
        raise RuntimeError("google status %r" % (data[0] if data else None))
    item = data[1][0]
    cands = item[1]
    meta = item[3] if len(item) > 3 and isinstance(item[3], dict) else {}
    lengths = meta.get("matched_length") or []
    notes = meta.get("annotation") or []
    out = []
    for i, text in enumerate(cands):
        matched = lengths[i] if i < len(lengths) else len(q)
        note = notes[i] if i < len(notes) else ""
        text = str(text).replace("\t", " ").replace("\n", " ").replace("\r", " ").strip()
        if text:
            out.append((int(matched), text, str(note).replace("\t", " ").replace("\n", " ")))
    return out


def lookup(q: str, engine: str = DEFAULT_ENGINE):
    """Try the engine set's input tools in order until one returns candidates."""
    cands = []
    for itc in ENGINES.get(engine, ENGINES[DEFAULT_ENGINE]):
        cands = fetch(q, itc)
        if cands:
            break
    return cands


def fetch(q: str, itc: str = ITC_PRIMARY):
    params = urllib.parse.urlencode({
        "text": q, "itc": itc, "num": NUM_CANDIDATES,
        "cp": 0, "cs": 1, "ie": "utf-8", "oe": "utf-8", "app": "demopage",
    })
    for attempt in (1, 2):
        conn = _connection()
        try:
            conn.request("GET", "/request?" + params, headers={"User-Agent": "rime-gcloud/0.1"})
            resp = conn.getresponse()
            body = resp.read()
        except (OSError, http.client.HTTPException):
            _drop_connection()  # stale keep-alive socket: reconnect once
            if attempt == 2:
                raise
            continue
        if resp.status != 200:
            raise RuntimeError("HTTP %d" % resp.status)
        return parse_response(body, q)
    raise RuntimeError("unreachable")


# ---------------------------------------------------------------- cache files

def write_atomic(path: str, text: str) -> None:
    tmp = "%s.%d.tmp" % (path, threading.get_ident())
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    os.replace(tmp, path)


def needs_fetch(q: str, engine: str = DEFAULT_ENGINE) -> bool:
    path = cache_path(q, engine)
    try:
        with open(path, "rb") as f:
            head = f.read(3)
        if head.startswith(b"OK"):
            try:
                os.utime(path)  # keep recently used entries when pruning
            except OSError:
                pass
            return False
        # ERR entry: retry once it is old enough
        return time.time() - os.path.getmtime(path) > ERR_RETRY_SECONDS
    except FileNotFoundError:
        return True
    except OSError:
        return True


def prune_cache() -> None:
    try:
        entries = [e for e in os.scandir(CACHE_DIR) if e.is_file()]
    except OSError:
        return
    stale_tmp = [e for e in entries if e.name.endswith(".tmp")]
    for e in stale_tmp:
        try:
            os.remove(e.path)
        except OSError:
            pass
    entries = [e for e in entries if e.name.endswith(".txt")]
    if len(entries) <= MAX_CACHE_FILES:
        return
    entries.sort(key=lambda e: e.stat().st_mtime)
    remove = len(entries) - int(MAX_CACHE_FILES * 0.8)
    for e in entries[:remove]:
        try:
            os.remove(e.path)
        except OSError:
            pass
    log.info("pruned %d cache files", remove)


def ensure_cache_version() -> None:
    """Drop cached results produced by a different engine setup."""
    try:
        with open(CACHE_VERSION_FILE, encoding="utf-8") as f:
            current = f.read().strip()
    except OSError:
        current = None
    if current == CACHE_VERSION:
        return
    removed = 0
    for e in os.scandir(CACHE_DIR):
        if e.is_file() and e.name.startswith("q_"):
            try:
                os.remove(e.path)
                removed += 1
            except OSError:
                pass
    write_atomic(CACHE_VERSION_FILE, CACHE_VERSION + "\n")
    log.info("cache cleared for engine change %r -> %r (%d files)", current, CACHE_VERSION, removed)


# ---------------------------------------------------------------- scheduler

class Scheduler:
    """Newest-first work queue so the latest keystroke is answered first.

    A job is a (query, engine) tuple."""

    def __init__(self):
        self.cv = threading.Condition()
        self.pending = deque()
        self.inflight = set()
        self.last_activity = time.time()
        self.latest = (None, False, 0.0)  # (job, push wanted, time) of the newest request
        self.warm_gen = 0  # bumped when typing resumes after a pause: workers re-warm at once

    def touch(self) -> None:
        """The user is typing (ping without text): keep the connections warm."""
        with self.cv:
            now = time.time()
            if now - self.last_activity > KEEPALIVE_SECONDS:
                self.warm_gen += 1
                self.cv.notify_all()
            self.last_activity = now

    def note_request(self, job, push: bool) -> None:
        with self.cv:
            self.latest = (job, push, time.time())

    def maybe_push(self, job) -> None:
        with self.cv:
            latest_job, push, t = self.latest
            if not push or latest_job != job or time.time() - t > PUSH_MAX_AGE_SECONDS:
                return
            self.latest = (latest_job, False, t)  # nudge once per request
        if not send_refresh_key():
            log.info("refresh key not sent (SendInput blocked?)")

    @staticmethod
    def keep_warm() -> None:
        try:
            fetch("nei")
        except Exception as e:
            log.info("warm-up failed: %s", e)

    def submit(self, job) -> None:
        with self.cv:
            if job in self.inflight or job in self.pending:
                return
            self.pending.append(job)
            while len(self.pending) > MAX_PENDING:
                self.pending.popleft()
            self.cv.notify()

    def worker(self) -> None:
        # Warm the TLS connection up front: the first handshake costs ~1 s.
        self.keep_warm()
        my_gen = self.warm_gen
        while True:
            warm_now = False
            with self.cv:
                while not self.pending:
                    if self.warm_gen != my_gen:
                        my_gen = self.warm_gen
                        warm_now = True  # typing resumed after a pause
                        break
                    if not self.cv.wait(timeout=KEEPALIVE_SECONDS):
                        break  # idle: maybe refresh the keep-alive socket
                if not self.pending:
                    job = None
                else:
                    job = self.pending.pop()
                    self.inflight.add(job)
                    self.last_activity = time.time()
            if job is None:
                if warm_now or time.time() - self.last_activity < KEEPALIVE_WHILE_ACTIVE_SECONDS:
                    self.keep_warm()
                continue
            q, engine = job
            t0 = time.perf_counter()
            try:
                cands = lookup(q, engine)
                body = "OK\n" + "".join("%d\t%s\t%s\n" % c for c in cands)
                write_atomic(cache_path(q, engine), body)
                self.maybe_push(job)
                ms = (time.perf_counter() - t0) * 1000
                if VERBOSE:
                    log.info("%s [%s] -> %d candidates in %.0f ms", q, engine, len(cands), ms)
            except Exception as e:  # network down, Google changed format, ...
                log.warning("lookup failed (%d chars, %s): %s", len(q), engine, e)
                try:
                    write_atomic(cache_path(q, engine), "ERR\t%s\n" % str(e).replace("\n", " "))
                except OSError:
                    pass
            finally:
                with self.cv:
                    self.inflight.discard(job)


# ---------------------------------------------------------------- main loop

def single_instance() -> bool:
    if os.name != "nt":
        return True
    kernel32 = ctypes.windll.kernel32
    handle = kernel32.CreateMutexW(None, False, "Local\\RimeGoogleCantoneseDaemon")
    globals()["_mutex_handle"] = handle  # keep it alive for the process lifetime
    return kernel32.GetLastError() != 183  # ERROR_ALREADY_EXISTS


def setup_logging() -> None:
    handler = logging.handlers.RotatingFileHandler(LOG_FILE, maxBytes=256_000, backupCount=1, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    log.addHandler(handler)
    log.setLevel(logging.INFO)


def run() -> None:
    os.makedirs(CACHE_DIR, exist_ok=True)
    setup_logging()
    if not single_instance():
        log.info("another daemon is already running; exiting")
        return
    log.info("daemon started (pid %d, engines %s)", os.getpid(),
             ", ".join("%s=%s" % (k, "+".join(v)) for k, v in ENGINES.items()))
    ensure_cache_version()
    prune_cache()

    sched = Scheduler()
    for _ in range(WORKERS):
        threading.Thread(target=sched.worker, daemon=True).start()

    last_stat = None
    last_content = None
    last_beat = 0.0
    last_prune = time.time()
    last_request = 0.0
    while True:
        now = time.time()
        if now - last_beat >= HEARTBEAT_EVERY_SECONDS:
            try:
                write_atomic(HEARTBEAT_FILE, "%d\n%d\n" % (int(now), os.getpid()))
            except OSError:
                pass
            last_beat = now
        if now - last_prune >= PRUNE_EVERY_SECONDS:
            prune_cache()
            last_prune = now
        try:
            st = os.stat(REQUEST_FILE)
            key = (st.st_mtime_ns, st.st_size)
        except OSError:
            key = None
        if key is not None and key != last_stat:
            last_stat = key
            try:
                with open(REQUEST_FILE, "r", encoding="ascii", errors="ignore") as f:
                    content = f.read()
            except OSError:
                content = None
            if content and content != last_content:
                last_content = content
                last_request = now
                lines = content.split("\n")
                q = lines[0].strip()
                push = len(lines) > 2 and lines[2].strip() == "1"
                engine = lines[3].strip() if len(lines) > 3 else ""
                if engine not in ENGINES:
                    engine = DEFAULT_ENGINE
                if q == "":
                    sched.touch()
                elif valid_query(q):
                    job = (q, engine)
                    sched.note_request(job, push)
                    if needs_fetch(q, engine):
                        sched.submit(job)
                    elif push:
                        sched.maybe_push(job)  # result landed just after Lua looked
        idle = now - last_request
        if idle < ACTIVE_WINDOW_SECONDS:
            time.sleep(POLL_ACTIVE_SECONDS)
        elif idle < WARM_WINDOW_SECONDS:
            time.sleep(POLL_WARM_SECONDS)
        else:
            time.sleep(POLL_IDLE_SECONDS)


def main(argv) -> int:
    global VERBOSE
    if "--once" in argv:
        q = argv[argv.index("--once") + 1]
        engine = argv[argv.index("--engine") + 1] if "--engine" in argv else DEFAULT_ENGINE
        t0 = time.perf_counter()
        cands = lookup(q, engine)
        sys.stdout.reconfigure(encoding="utf-8")
        print("%.0f ms" % ((time.perf_counter() - t0) * 1000))
        for c in cands:
            print("%d\t%s\t%s" % c)
        return 0
    VERBOSE = "--verbose" in argv
    run()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
