#!/usr/bin/env python3
"""Real GTK4 + XTest regression for drag on a handle inside a moving block."""
import ctypes
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from test_gui_real_gtk import (
    load_x11, start_xvfb, wait_for_ready, find_window, finish_with_timeout,
    kill_and_collect, format_output, decode, skip,
)

ROOT = Path(__file__).resolve().parent.parent
TITLE = "Babet real GTK drag probe"

def inject_drag(x11, xtst, display, window):
    root = x11.XDefaultRootWindow(display)
    rx, ry, child = ctypes.c_int(), ctypes.c_int(), ctypes.c_ulong()
    if not x11.XTranslateCoordinates(display, window, root, 0, 0,
                                     ctypes.byref(rx), ctypes.byref(ry), ctypes.byref(child)):
        raise AssertionError("XTranslateCoordinates failed")
    # GtkFixed block at (20,20), width 180, height 60. Center of label in block.
    px, py = rx.value + 65, ry.value + 50
    def move(x, y):
        if not xtst.XTestFakeMotionEvent(display, -1, x, y, 0):
            raise AssertionError("XTestFakeMotionEvent failed")
        x11.XFlush(display)
        time.sleep(0.03)
    move(px, py)
    if not xtst.XTestFakeButtonEvent(display, 1, 1, 0):
        raise AssertionError("XTestFakeButtonEvent down failed")
    x11.XFlush(display)
    time.sleep(0.08)
    for step in range(1, 11):
        move(px + step * 10, py + step * 5)
    if not xtst.XTestFakeButtonEvent(display, 1, 0, 0):
        raise AssertionError("XTestFakeButtonEvent up failed")
    x11.XFlush(display)

def main():
    if len(sys.argv) != 2:
        raise AssertionError("usage: test_gui_real_drag.py /path/to/babet")
    xvfb = shutil.which("Xvfb")
    if not xvfb: return skip("Xvfb is unavailable")
    try: ctypes.CDLL("libgtk-4.so.1")
    except OSError: return skip("libgtk-4.so.1 is unavailable")
    libraries = load_x11()
    if libraries is None: return skip("X11/XTest runtime libraries are unavailable")
    x11, xtst = libraries
    server, display_name = start_xvfb(xvfb)
    if not server: return skip("cannot start private Xvfb")
    conn, child = None, None
    try:
        for _ in range(60):
            conn = x11.XOpenDisplay(display_name.encode())
            if conn: break
            time.sleep(0.04)
        if not conn: return skip("Xlib cannot connect to Xvfb")
        env = dict(os.environ)
        env.pop("LD_LIBRARY_PATH", None)
        for key in list(env):
            if key.startswith("BABET_FAKE_GTK") or key.startswith("BABET_CAIRO_"):
                env.pop(key, None)
        env.update(DISPLAY=display_name, GDK_BACKEND="x11", G_DEBUG="fatal-criticals")
        env["ASAN_OPTIONS"] = (env.get("ASAN_OPTIONS", "") + ":detect_leaks=0").strip(":")
        child = subprocess.Popen(
            [str(Path(sys.argv[1]).resolve()), str(ROOT / "tests/gui/real_gtk_drag.lua")],
            env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out0, err0 = wait_for_ready(child, 20, b"REAL_GTK_DRAG_READY\n")
        if b"REAL_GTK_DRAG_READY" not in out0:
            raise AssertionError("GTK drag canvas never rendered")
        target = None
        for _ in range(120):
            target = find_window(x11, conn, TITLE)
            if target: break
            if child.poll() is not None: break
            time.sleep(0.04)
        if not target:
            out, err = kill_and_collect(child, out0, err0)
            raise AssertionError("GTK drag window missing\n" + format_output(out, err))
        # Rendering has completed before injection, and Xlib located the window.
        time.sleep(0.15)
        inject_drag(x11, xtst, conn, target)
        out, err = finish_with_timeout(child, 15, out0, err0)
        if child.returncode != 0 or "REAL_GTK_DRAG_OK" not in decode(out):
            raise AssertionError("GtkFixed drag did not follow pointer\n" + format_output(out, err))
        print("[PASS] real GTK4: onDrag on moving handle follows 100x50 pointer motion")
        return 0
    finally:
        if conn: x11.XCloseDisplay(conn)
        if child and child.poll() is None:
            child.terminate()
            try: child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait(timeout=2)
        server.terminate()
        try: server.wait(timeout=2)
        except subprocess.TimeoutExpired:
            server.kill(); server.wait(timeout=2)

if __name__ == "__main__":
    try: sys.exit(main())
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"[FAIL] real GTK4 drag: {error}", file=sys.stderr)
        sys.exit(1)
