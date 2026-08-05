#!/usr/bin/env python3
"""Protocol smoke test for aeasy-server (see specs/2026-08-05-multi-source-panes.md).

Runs the real server against a scratch config on a spare port via AEASY_DIR/AEASY_PORT,
so a live session's config, layout and port are never touched.

Preconditions: Screen Recording granted to mac/aeasy-server (Accessibility too, for T-16).
The server creates its virtual display while the test runs, so a display briefly appears
in System Settings — that is the product working, not a leak.

    python3 test/smoke.py            # full run
    python3 test/smoke.py -v         # show every assertion
"""

import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = os.path.join(ROOT, "mac", "aeasy-server")
PORT = 7399
PANEL = ("720", "1650")
START_CODE = b"\x00\x00\x00\x01"

VERBOSE = "-v" in sys.argv
results = []      # (name, covers, ok, detail)


def record(name, covers, ok, detail=""):
    results.append((name, covers, ok, detail))
    if VERBOSE or not ok:
        print(f"  {'ok  ' if ok else 'FAIL'} {name} [{covers}] {detail}")


def check(name, covers, cond, detail=""):
    record(name, covers, bool(cond), detail)
    return bool(cond)


# --- server lifecycle -------------------------------------------------------

class Server:
    # port/panel/slot are per instance, not module constants: the multi-device suite runs
    # two or three of these at once, and two instances on one port cannot both bind.
    def __init__(self, sources, bitrate=2000000, reuse_dir=None,
                 port=PORT, panel=PANEL, slot=None, extra_conf=()):
        self.dir = reuse_dir or tempfile.mkdtemp(prefix="aeasy-smoke-")
        self.port = port
        self.slot = slot if slot is not None else (port - PORT) // 10
        conf = [f"SOURCES={sources}", "FPS=20", "SCALE=60", "CODEC=h264", f"BITRATE={bitrate}"]
        conf += list(extra_conf)
        with open(os.path.join(self.dir, "config"), "w") as f:
            f.write("\n".join(conf) + "\n")
        self.log = open(os.path.join(self.dir, "server.log"), "w+")
        env = dict(os.environ, AEASY_DIR=self.dir, AEASY_PORT=str(port))
        argv = [SERVER, *panel, "--slot", str(self.slot)]
        self.p = subprocess.Popen(argv, stdout=self.log, stderr=subprocess.STDOUT, env=env)

    def set_conf(self, key, value):
        """Rewrite one key in this server's config, the way the tray and the GUI do."""
        path = os.path.join(self.dir, "config")
        with open(path) as f:
            lines = [l for l in f.read().splitlines() if not l.startswith(key + "=")]
        lines.append(f"{key}={value}")
        with open(path, "w") as f:
            f.write("\n".join(lines) + "\n")

    def wait_ready(self, timeout=15):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.p.poll() is not None:
                return False
            if "listening on" in self.text():
                time.sleep(0.4)   # let startCapture settle
                return True
            time.sleep(0.2)
        return False

    def text(self):
        self.log.flush()
        with open(self.log.name) as f:
            return f.read()

    def layout_path(self):
        return os.path.join(self.dir, "layout.json")

    def stop(self):
        try:
            self.p.terminate()
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()
        self.log.close()

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)


# --- client helpers ---------------------------------------------------------

def connect(timeout=3, port=PORT):
    s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    s.settimeout(timeout)
    return s


def hello(spec, port=PORT):
    s = connect(port=port)
    s.sendall(b"AEZ1 " + spec.encode() + b"\n")
    return s


def read_for(s, seconds, want=None):
    """Accumulate bytes for `seconds`, or until `want` appears."""
    end = time.time() + seconds
    buf = b""
    s.settimeout(0.3)
    while time.time() < end:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            continue
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        if want and want(buf):
            break
    return buf


def wait_closed(s, timeout=2.0):
    """True only on a real EOF from the peer, not on a quiet socket."""
    end = time.time() + timeout
    while time.time() < end:
        s.settimeout(max(0.05, end - time.time()))
        try:
            if s.recv(65536) == b"":
                return True
        except socket.timeout:
            return False
        except OSError:
            return True
    return False


def nal_types(buf):
    """Annex-B NAL type numbers (H.264) in order."""
    out = []
    for part in buf.split(START_CODE)[1:]:
        if part:
            out.append(part[0] & 0x1F)
    return out


def send_ctl(s, obj):
    body = json.dumps(obj).encode()
    s.sendall(struct.pack(">I", len(body)) + body)


class Control:
    """Length-prefixed JSON control client."""

    def __init__(self, port=PORT):
        self.s = hello("control", port=port)
        self.buf = b""

    def recv(self, want_t=None, timeout=3):
        end = time.time() + timeout
        while time.time() < end:
            msg = self._pop()
            if msg and (want_t is None or msg.get("t") == want_t):
                return msg
            if msg:
                continue
            self.s.settimeout(max(0.05, end - time.time()))
            try:
                chunk = self.s.recv(65536)
            except socket.timeout:
                break
            except OSError:
                break
            if not chunk:
                break
            self.buf += chunk
        return None

    def _pop(self):
        if len(self.buf) < 4:
            return None
        n = struct.unpack(">I", self.buf[:4])[0]
        if len(self.buf) < 4 + n:
            return None
        body = self.buf[4:4 + n]
        self.buf = self.buf[4 + n:]
        return json.loads(body)

    def send(self, obj):
        send_ctl(self.s, obj)

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def touch_packet(t, x, y):
    return struct.pack(">BHH", t, x, y)


def cursor():
    """Current mouse location in CG global (top-left origin) coordinates."""
    out = subprocess.run(
        ["osascript", "-l", "JavaScript", "-e",
         'ObjC.import("CoreGraphics");'
         'var e=$.CGEventCreate($()); var p=$.CGEventGetLocation(e);'
         'p.x + "," + p.y'],
        capture_output=True, text=True)
    try:
        x, y = out.stdout.strip().split(",")
        return float(x), float(y)
    except Exception:
        return None


# --- single-source suite ----------------------------------------------------

def run_single(srv):
    # T-1: keyframe on subscribe, without touching the Mac
    s = hello("display")
    buf = read_for(s, 1.5, want=lambda b: 5 in nal_types(b))
    types = nal_types(buf)
    check("T-1 keyframe on subscribe", "FR-5, FR-22",
          7 in types and 8 in types and 5 in types,
          f"NAL types seen: {sorted(set(types))}")
    s.close()

    # T-2: unknown source is rejected in full, then closed
    s = connect()
    s.sendall(b"AEZ1 bogus\n")
    reply = read_for(s, 1.5, want=lambda b: b.endswith(b"\n"))
    closed = wait_closed(s)
    check("T-2 unknown source rejected", "FR-6",
          reply.startswith(b"AEZ1 ERR") and reply.endswith(b"\n") and closed,
          f"reply={reply!r} closed={closed}")
    s.close()

    # T-3a: a legacy client whose first bytes are a touch packet still gets video
    s = connect()
    s.sendall(touch_packet(2, 100, 100))     # type 2 = up, harmless
    buf = read_for(s, 2.0, want=lambda b: START_CODE in b)
    check("T-3a legacy touch-first client gets video", "FR-5, NFR-10",
          START_CODE in buf, f"{len(buf)} bytes")
    s.close()

    # T-3b: a silent client is adopted after the handshake deadline
    s = connect()
    t0 = time.time()
    buf = read_for(s, 2.5, want=lambda b: START_CODE in b)
    elapsed = time.time() - t0
    check("T-3b silent client adopted after 300ms", "FR-5, NFR-10",
          START_CODE in buf and elapsed >= 0.25,
          f"first video after {elapsed:.2f}s")
    s.close()

    # T-4: a handshake that misses the deadline mid-line is closed, not misread as touch
    s = connect()
    s.sendall(b"AEZ1 dis")
    time.sleep(0.45)
    try:
        s.sendall(b"play\n")
    except OSError:
        pass
    tail = read_for(s, 1.5)
    check("T-4 late handshake closed", "FR-5",
          b"ERR" in tail or tail == b"", f"tail={tail[:40]!r}")
    s.close()
    s = hello("display")   # and the connection after it still works
    check("T-4b clean handshake still works", "FR-5",
          START_CODE in read_for(s, 2.0, want=lambda b: START_CODE in b))
    s.close()

    # T-5: control hello
    c = Control()
    vp = c.recv("viewport")
    sm = c.recv("sources")
    lm = c.recv("layout")
    ok = (vp and vp["w"] == int(PANEL[0]) and vp["h"] == int(PANEL[1])
          and sm and sm["sources"] and all(k in sm["sources"][0] for k in ("id", "w", "h", "fps", "bitrate"))
          and lm and "rev" in lm and lm["panes"])
    check("T-5 control hello: viewport + sources + layout", "FR-7, FR-9, FR-13", ok,
          f"viewport={vp} sources={sm} layout_rev={(lm or {}).get('rev')}")

    # T-6: proposal is acked to the proposer and broadcast to the other client, under 200ms
    c2 = Control()
    c2.recv("layout")
    rev0 = lm["rev"]
    panes = [dict(p) for p in lm["panes"]]
    panes[0]["x"] = 0.0
    panes[0]["w"] = 0.5
    t0 = time.time()
    c.send({"t": "layout", "panes": panes, "tok": "abc"})
    ack = c.recv("layout")
    other = c2.recv("layout")
    dt = time.time() - t0
    check("T-6 proposal acked, broadcast, rev+1, <200ms", "FR-11, NFR-9",
          ack and ack["rev"] == rev0 + 1 and ack.get("ack") == "abc"
          and other and other["rev"] == rev0 + 1 and dt < 0.2,
          f"rev {rev0}->{(ack or {}).get('rev')} ack={(ack or {}).get('ack')} in {dt*1000:.0f}ms")

    # T-7: a proposal that omits an active source is rejected wholesale
    rev1 = ack["rev"]
    c.send({"t": "layout", "panes": [], "tok": "empty"})
    snap = c.recv("layout")
    check("T-7 incomplete proposal rejected", "FR-10, FR-11",
          snap and snap["rev"] == rev1 and snap.get("ack") is None,
          f"rev stayed {(snap or {}).get('rev')}")

    # T-8: clamping, with a rev bump
    panes = [dict(p) for p in snap["panes"]]
    panes[0].update({"x": 1.4, "y": -0.5, "w": 0.05, "h": 0.05})
    c.send({"t": "layout", "panes": panes, "tok": "clamp"})
    cl = c.recv("layout")
    p0 = cl["panes"][0] if cl else {}
    check("T-8 out-of-range pane clamped, rev bumped", "FR-11",
          cl and cl["rev"] == rev1 + 1
          and abs(p0.get("w", 0) - 0.15) < 1e-6 and abs(p0.get("h", 0) - 0.15) < 1e-6
          and 0 <= p0.get("x", -1) <= 0.85 and 0 <= p0.get("y", -1) <= 0.85,
          f"pane={p0}")

    # T-15b: an oversized control frame is refused
    s = hello("control")
    time.sleep(0.2)
    s.sendall(struct.pack(">I", 100 * 1024 * 1024) + b"{}")
    check("T-15b oversized control frame closes the connection", "NFR-3",
          wait_closed(s, 2.5), "no 100MiB allocation, peer hung up")
    s.close()

    # T-13: layout.json holds the bumped rev and survives a restart
    time.sleep(0.9)   # persist is debounced 500ms
    saved = {}
    try:
        with open(srv.layout_path()) as f:
            saved = json.load(f)
    except Exception as e:
        saved = {"error": str(e)}
    check("T-13 layout.json persisted at current rev", "FR-9, FR-28",
          saved.get("rev") == cl["rev"], f"file rev={saved.get('rev')} live rev={cl['rev']}")

    # T-16: a touch on the display source moves the cursor
    before = cursor()
    s = hello("display")
    read_for(s, 1.0, want=lambda b: START_CODE in b)
    s.sendall(touch_packet(1, 8000, 8000))   # type 1 = drag/move, no click
    time.sleep(0.4)
    after = cursor()
    if before is None or after is None:
        record("T-16 display touch moves the cursor", "FR-19", False, "could not read cursor position")
    else:
        check("T-16 display touch moves the cursor", "FR-19", before != after,
              f"{before} -> {after}")
    s.close()

    c.close()
    c2.close()
    return saved.get("rev")


# --- multi-source suite -----------------------------------------------------

def find_app():
    """Ask the server which apps have on-screen windows by making it miss on purpose."""
    srv = Server("display,window:zzz-no-such-app-zzz")
    try:
        started = srv.wait_ready()
        # the missing window is skipped, not fatal, and does not fall back to window mode
        check("T-19 unfindable window source skipped", "FR-3",
              started and "not found — skipping" in srv.text() and "sources: display" in srv.text(),
              "server came up with the remaining source")
        m = re.search(r"running apps: (.+)", srv.text())
        if not m:
            return None
        names = [n.strip() for n in m.group(1).split(",") if n.strip()]
        skip = {"aeasy-server", "Python", "python3"}
        for n in names:
            if n not in skip:
                return n
        return None
    finally:
        srv.stop()
        srv.cleanup()


def run_multi(app):
    # BITRATE below the 3-source floor, to exercise NFR-5
    srv = Server(f"window:{app},display", bitrate=500000)
    try:
        if not srv.wait_ready():
            record("multi-source server start", "FR-1", False, srv.text()[-400:])
            return
        c = Control()
        c.recv("viewport")
        sm = c.recv("sources")
        ids = [s["id"] for s in (sm or {}).get("sources", [])]

        # T-10: display is forced primary even though the config lists it second
        check("T-10 display forced to primary", "FR-2",
              ids and ids[0] == "display", f"order={ids}")

        if len(ids) < 2:
            record("T-9 concurrent sockets per source", "FR-1, FR-8", False,
                   f"only {len(ids)} source(s) came up: {ids}")
            c.close()
            return

        # T-17: budget floor and 60/20 split with BITRATE=500000 below the floor
        rates = {s["id"]: s["bitrate"] for s in sm["sources"]}
        total = sum(rates.values())
        expected_total = max(500000, 300000 * len(ids))
        check("T-17 bitrate floor and split", "NFR-5",
              total == expected_total and rates[ids[0]] == expected_total * 6 // 10,
              f"total={total} expected={expected_total} rates={rates}")

        # T-9: two sockets on the primary plus one on the secondary, all independent
        socks = [hello(ids[0]), hello(ids[0]), hello(ids[1])]
        got = [START_CODE in read_for(s, 2.5, want=lambda b: START_CODE in b) for s in socks]
        check("T-9 concurrent sockets per source", "FR-1, FR-8", all(got), f"video per socket: {got}")
        for s in socks:
            s.close()

        # T-14: a layout naming a dead source is dropped and defaults added on load
        c.close()
        srv.stop()
        time.sleep(0.3)
        with open(srv.layout_path(), "w") as f:
            json.dump({"rev": 41, "panes": [
                {"src": "window:zzz-gone", "x": 0, "y": 0, "w": 1, "h": 1, "z": 0}]}, f)
        again = Server(f"window:{app},display", bitrate=500000, reuse_dir=srv.dir)
        try:
            if not again.wait_ready():
                record("T-14 stale layout reconciled on load", "FR-9", False, "server did not restart")
                return
            c3 = Control()
            c3.recv("viewport")
            c3.recv("sources")
            lm = c3.recv("layout")
            srcs = sorted(p["src"] for p in (lm or {}).get("panes", []))
            check("T-14 stale layout reconciled on load", "FR-9",
                  lm and lm["rev"] > 41 and "window:zzz-gone" not in srcs and len(srcs) == len(ids),
                  f"rev={(lm or {}).get('rev')} panes={srcs}")
            c3.close()
        finally:
            again.stop()
    finally:
        srv.stop()
        srv.cleanup()


# --- multi-device suite -----------------------------------------------------
# See specs/2026-08-06-multi-device-targets.md. Two servers at once is the whole claim:
# per-device state comes from AEASY_DIR, per-device identity from AEASY_PORT.

def listens_on_loopback(port):
    out = subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN"],
                         capture_output=True, text=True).stdout
    return bool(out.strip()) and "127.0.0.1" in out and "*:" not in out


def run_multi_device():
    a = Server("display", port=PORT, slot=0)
    b = Server("display", port=PORT + 10, slot=1, extra_conf=["INPUT=0"])
    try:
        if not a.wait_ready() or not b.wait_ready():
            record("T-14 two servers coexist", "FR-15, NFR-1", False,
                   "second server did not start:\n" + b.text())
            return
        check("T-14 two servers coexist", "FR-15, NFR-1", True, f"ports {a.port} and {b.port}")

        # T-18: distinct display identity. serialNum is derived from the port, which is
        # what stops macOS collapsing the two displays' saved arrangements into one.
        check("T-18 slot 1 names its display distinctly", "FR-25",
              "AEasy Display 2" in b.text(), "startup log names the display")
        check("T-18 slot 0 keeps the original display name", "FR-25, NFR-4",
              "'AEasy Display'" in a.text() or "AEasy Display id=" in a.text())

        # T-19: every slot binds loopback only
        check("T-19 both listeners are loopback-only", "NFR-3",
              listens_on_loopback(a.port) and listens_on_loopback(b.port))

        # T-16: per-device layout. A drag on slot 1 must not touch slot 0's file.
        ca, cb = Control(port=a.port), Control(port=b.port)
        la, lb = ca.recv("layout"), cb.recv("layout")
        if la and lb:
            cb.send({"t": "layout", "tok": "x",
                     "panes": [dict(p, x=0.25) for p in lb["panes"]]})
            cb.recv("layout")
            time.sleep(0.8)   # the server debounces layout.json by 500 ms
            ra = json.load(open(a.layout_path())) if os.path.exists(a.layout_path()) else {}
            rb = json.load(open(b.layout_path())) if os.path.exists(b.layout_path()) else {}
            check("T-16 layout is per device", "FR-3",
                  rb.get("rev", 0) > la["rev"] and ra.get("rev", 0) == la["rev"],
                  f"slot0 rev={ra.get('rev')} slot1 rev={rb.get('rev')}")
        else:
            record("T-16 layout is per device", "FR-3", False, "no layout on connect")

        # T-14 (continued): adding/removing a device leaves the other's stream alone.
        # Deliberately not asserted: "no frame gap" — ScreenCaptureKit is change-driven,
        # so an idle desktop legitimately emits nothing for seconds at a time.
        va = hello("display", port=a.port)
        read_for(va, 1.5, want=lambda x: START_CODE in x)
        subs_before = a.text().count("subscribed")
        c = Server("display", port=PORT + 20, slot=2)
        try:
            c.wait_ready()
            time.sleep(0.5)
            still = a.text()
            check("T-15 starting a third server does not disturb the first", "FR-15",
                  still.count("subscribed") == subs_before and a.p.poll() is None,
                  "no reconnect on slot 0")
        finally:
            c.stop(); c.cleanup()
        check("T-15 slot 0 survives a third server's teardown", "FR-15",
              a.p.poll() is None and b.p.poll() is None)

        # T-11/T-12: input arbitration. Slot 1 was started with INPUT=0.
        before = cursor()
        vb = hello("display", port=b.port)
        read_for(vb, 1.0, want=lambda x: START_CODE in x)
        vb.sendall(touch_packet(1, 8000, 8000))
        time.sleep(0.5)
        mid = cursor()
        if before is None or mid is None:
            record("T-11 non-input device cannot move the cursor", "FR-23", False,
                   "could not read cursor position")
        else:
            check("T-11 non-input device cannot move the cursor", "FR-23", before == mid,
                  f"{before} -> {mid}")
            # T-12: flip INPUT on disk; the change is picked up on the touch path within a
            # second, with no restart and no reconnect.
            b.set_conf("INPUT", "1")
            time.sleep(1.2)
            vb.sendall(touch_packet(1, 20000, 20000))
            time.sleep(0.5)
            after = cursor()
            check("T-12 flipping INPUT transfers control without a restart", "FR-23",
                  after is not None and after != mid and b.p.poll() is None,
                  f"{mid} -> {after}")
        vb.close(); va.close(); ca.close(); cb.close()
    finally:
        for s in (a, b):
            s.stop(); s.cleanup()


def run_panel_lock():
    """T-17: PANEL pins the display size and disarms the type-3 restart."""
    srv = Server("display", port=PORT, slot=0, panel=("720", "1650"),
                 extra_conf=["PANEL=800 600"])
    try:
        if not srv.wait_ready():
            record("T-17 PANEL locks the display size", "FR-21", False, "server did not start")
            return
        c = Control(port=srv.port)
        vp = c.recv("viewport")
        check("T-17 PANEL locks the display size", "FR-21",
              vp and vp.get("w") == 800 and vp.get("h") == 600,
              f"viewport={vp} (argv said 720x1650)")
        # a type-3 reporting something else must neither write dims.ios nor exit
        v = hello("display", port=srv.port)
        read_for(v, 1.0, want=lambda x: START_CODE in x)
        v.sendall(struct.pack(">BHH", 3, 390, 844))
        time.sleep(1.0)
        check("T-17 PANEL disarms the type-3 restart", "FR-22",
              srv.p.poll() is None and not os.path.exists(os.path.join(srv.dir, "dims.ios")),
              "no exit, no dims.ios")
        v.close(); c.close()
    finally:
        srv.stop(); srv.cleanup()


# --- main -------------------------------------------------------------------

def main():
    if not os.path.exists(SERVER):
        print("aeasy-server not built — run `make build` first")
        return 1

    print("smoke: single-source suite")
    srv = Server("display")
    try:
        if not srv.wait_ready():
            print("server failed to start:\n" + srv.text())
            return 1
        run_single(srv)
    finally:
        srv.stop()
        srv.cleanup()

    print("smoke: multi-source suite")
    app = find_app()
    if app:
        print(f"  using window source: {app}")
        run_multi(app)
    else:
        print("  SKIPPED — no app with an on-screen window found "
              "(T-9, T-10, T-14, T-17 need a second source)")

    print("smoke: multi-device suite")
    run_multi_device()
    print("smoke: panel-lock suite")
    run_panel_lock()

    failed = [r for r in results if not r[2]]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
    if failed:
        print("failed:")
        for name, covers, _, detail in failed:
            print(f"  - {name} [{covers}] {detail}")
    print("\nnot covered here (see the spec's manual matrix): T-11/M-5 step-down under load, "
          "T-12 source teardown, T-18 CLI, T-15a non-loopback refusal, M-1..M-10")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
