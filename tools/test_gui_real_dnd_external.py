#!/usr/bin/env python3
"""Real GTK4 + XTest regression for drops coming from another process.

A separate GTK4 process (tests/gui/real_gtk_dnd_source.py) offers either a
file list, like a file manager, or a link, like a browser. Babet must report
the action actually negotiated with that source, including when a child target
refuses hover and its parent accepts, and must classify mixed text/file drops.
Missing GTK4, Xvfb, X11 or XTest support is an explicit SKIP.
"""
import ctypes
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from test_gui_real_gtk import (
    load_x11, start_xvfb, wait_for_ready, find_window, finish_with_timeout,
    kill_and_collect, format_output, decode, skip,
)

ROOT = Path(__file__).resolve().parent.parent
SOURCE_TITLE = "Babet external drag source"
TARGET_TITLE = "Babet external drop target"
LINK = "https://example.com/page"
COPY, MOVE = 1, 2


def cases(folder):
    first, second = str(folder / "image été.png"), str(folder / "second.png")
    files = [first, second]
    paths = first + "|" + second
    return [
        # mode, source kind, source actions, items, expected drop line
        ("nested", "files", COPY | MOVE, files, "kind=files action=copy payload=" + paths),
        # Release right after entering: GTK keeps the parent's enter status.
        ("nested-enter", "files", COPY | MOVE, files, "kind=files action=move payload=" + paths),
        ("mixed-files", "files", COPY | MOVE, files, "kind=files action=copy payload=" + paths),
        ("mixed-link", "uris", COPY, [LINK], "kind=text action=copy payload=" + LINK),
        ("source-copy", "uris", COPY, [LINK], "kind=text action=copy payload=" + LINK),
        ("hover-copy", "uris", COPY | MOVE, [LINK], "kind=text action=copy payload=" + LINK),
    ]


def window_origin(x11, display, window):
    root = x11.XDefaultRootWindow(display)
    x, y, child = ctypes.c_int(), ctypes.c_int(), ctypes.c_ulong()
    if not x11.XTranslateCoordinates(display, window, root, 0, 0,
                                     ctypes.byref(x), ctypes.byref(y), ctypes.byref(child)):
        raise AssertionError("XTranslateCoordinates failed")
    return x.value, y.value


def wait_window(x11, display, title, children):
    for _ in range(150):
        window = find_window(x11, display, title)
        if window:
            return window
        if any(child.poll() is not None for child in children):
            break
        time.sleep(0.04)
    raise AssertionError(title + " window missing")


def drag(x11, xtst, display, start, end, jump=False):
    def motion(x, y):
        if not xtst.XTestFakeMotionEvent(display, -1, x, y, 0):
            raise AssertionError("XTestFakeMotionEvent failed")
        x11.XFlush(display)
    def button(down):
        if not xtst.XTestFakeButtonEvent(display, 1, down, 0):
            raise AssertionError("XTestFakeButtonEvent failed")
        x11.XFlush(display)
    motion(*start)
    time.sleep(0.3)
    button(1)
    time.sleep(0.2)
    if jump:
        # Start the drag inside the source, then send a single position inside
        # the target: on X11 that is an enter event without any motion event.
        for step in range(1, 6):
            motion(start[0] + step * 6, start[1])
            time.sleep(0.05)
        time.sleep(0.4)
        motion(*end)
        time.sleep(0.6)
        button(0)
        return
    for step in range(1, 41):
        motion(start[0] + (end[0] - start[0]) * step // 40, start[1] + step % 3)
        time.sleep(0.03)
    time.sleep(0.4)
    motion(*end)
    time.sleep(0.4)
    button(0)


def stop(child):
    if child and child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=2)


def run_case(binary, env, x11, xtst, display, case):
    mode, kind, actions, items, expected = case
    target = subprocess.Popen(
        [binary, str(ROOT / "tests/gui/real_gtk_dnd_external.lua"), mode], env=env,
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    source = None
    try:
        target_out, target_err = wait_for_ready(target, 20, b"EXTERNAL_TARGET_READY")
        source = subprocess.Popen(
            [sys.executable, "-I", str(ROOT / "tests/gui/real_gtk_dnd_source.py"),
             kind, str(actions), *items], env=env,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        source_out, source_err = wait_for_ready(source, 20, b"EXTERNAL_SOURCE_READY")
        source_window = wait_window(x11, display, SOURCE_TITLE, [source, target])
        target_window = wait_window(x11, display, TARGET_TITLE, [source, target])
        x11.XMoveWindow(display, source_window, 20, 20)
        x11.XMoveWindow(display, target_window, 400, 20)
        x11.XFlush(display)
        time.sleep(0.8)  # let both toplevels map and render at their new place
        sx, sy = window_origin(x11, display, source_window)
        tx, ty = window_origin(x11, display, target_window)
        drag(x11, xtst, display, (sx + 100, sy + 100), (tx + 150, ty + 100), mode == "nested-enter")
        target_out, target_err = finish_with_timeout(target, 10, target_out, target_err)
        text = decode(target_out)
        if target.returncode != 0 or "EXTERNAL_DROP " + expected not in text \
                or "EXTERNAL_PARENT_DROP" in text or b"callback error" in target_err:
            raise AssertionError(mode + ": unexpected drop\n" + format_output(target_out, target_err))
        source_out, source_err = wait_for_ready(source, 10, b"EXTERNAL_SOURCE_END")
        # The source must have selected the same action as the one Babet reported.
        wanted = "selected=%d" % (COPY if "action=copy" in expected else MOVE)
        if wanted not in decode(source_out):
            raise AssertionError(mode + ": source selected another action\n"
                                 + format_output(source_out, source_err))
    except BaseException:
        if target.poll() is None:
            out, err = kill_and_collect(target)
            sys.stderr.write(format_output(out, err) + "\n")
        raise
    finally:
        stop(source)
        stop(target)
    print(f"[PASS] real GTK4 external drop: {mode} ({expected.split(' payload=')[0]})")


def main():
    if len(sys.argv) != 2:
        raise AssertionError("usage: test_gui_real_dnd_external.py /path/to/babet")
    binary = str(Path(sys.argv[1]).resolve())
    xvfb = shutil.which("Xvfb")
    if not xvfb: return skip("Xvfb is unavailable (external drops)")
    try: gtk = ctypes.CDLL("libgtk-4.so.1")
    except OSError: return skip("libgtk-4.so.1 is unavailable (external drops)")
    if not hasattr(gtk, "gdk_file_list_new_from_array"):
        return skip("GTK older than 4.8 cannot build the file-list source (external drops)")
    libraries = load_x11()
    if libraries is None: return skip("X11/XTest runtime libraries are unavailable (external drops)")
    x11, xtst = libraries
    x11.XMoveWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int]
    x11.XMoveWindow.restype = ctypes.c_int
    server, display_name = start_xvfb(xvfb)
    if not server: return skip("cannot start private Xvfb (external drops)")
    display = None
    try:
        for _ in range(60):
            display = x11.XOpenDisplay(display_name.encode())
            if display: break
            time.sleep(0.04)
        if not display: return skip("Xlib cannot connect to Xvfb (external drops)")
        env = dict(os.environ)
        env.pop("LD_LIBRARY_PATH", None)
        for key in list(env):
            if key.startswith(("BABET_FAKE_GTK", "BABET_CAIRO_", "DBUS_")) or key == "WAYLAND_DISPLAY":
                env.pop(key, None)
        env.update(DISPLAY=display_name, GDK_BACKEND="x11", GSK_RENDERER="cairo",
                   GTK_A11Y="none", LC_ALL="C.UTF-8", G_DEBUG="fatal-criticals")
        env["ASAN_OPTIONS"] = (env.get("ASAN_OPTIONS", "") + ":detect_leaks=0").strip(":")
        with tempfile.TemporaryDirectory(prefix="babet_external_dnd_") as tmp:
            folder = Path(tmp)
            for name in ["image été.png", "second.png"]:
                (folder / name).write_bytes(b"")
            env["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=" + str(folder / "no-session-bus")
            all_cases = cases(folder)
            for case in all_cases:
                run_case(binary, env, x11, xtst, display, case)
        print(f"Real GTK external drops: {len(all_cases)} PASS / 0 FAIL")
        return 0
    finally:
        if display: x11.XCloseDisplay(display)
        server.terminate()
        try: server.wait(timeout=2)
        except subprocess.TimeoutExpired:
            server.kill(); server.wait(timeout=2)


if __name__ == "__main__":
    try: sys.exit(main())
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"[FAIL] real GTK4 external drops: {error}", file=sys.stderr)
        sys.exit(1)
