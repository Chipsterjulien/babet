#!/usr/bin/env python3
"""Optional regression against the system GTK4 under a private Xvfb server.

The fake GTK remains the deterministic fault-injection harness. This test is a
second line of defense for observable behavior that a fake toolkit can model
incorrectly. It also injects a real double click through XTest so DrawingArea's
button/n_press contract is exercised against GTK itself.

Missing GTK4, Xvfb, X11 or XTest support is an explicit SKIP, never a failure.
"""
import ctypes
import ctypes.util
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
WINDOW_TITLE = "Babet real GTK click probe"
READY_MARKER = b"REAL_GTK_READY\n"


def skip(reason):
    print(f"[SKIP] real GTK4 regression: {reason}")
    return 0


def decode(data):
    return data.decode("utf-8", "replace")


def format_output(stdout, stderr):
    return (
        f"stdout:\n{decode(stdout)[-5000:]}\n"
        f"stderr:\n{decode(stderr)[-8000:]}"
    )


def kill_and_collect(child, stdout_prefix=b"", stderr_prefix=b""):
    """Stop a still-running child and return every captured output byte."""
    if child.poll() is None:
        child.kill()
    stdout, stderr = child.communicate()
    return stdout_prefix + stdout, stderr_prefix + stderr


def finish_with_timeout(child, timeout, stdout_prefix=b"", stderr_prefix=b""):
    """Collect child output, killing it on timeout while preserving diagnostics."""
    try:
        stdout, stderr = child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        partial_stdout = error.output or b""
        partial_stderr = error.stderr or b""
        stdout, stderr = kill_and_collect(child)
        # CPython normally returns the complete capture on the retry, but keep
        # TimeoutExpired's partial buffers as a defensive fallback.
        if not stdout and partial_stdout:
            stdout = partial_stdout
        if not stderr and partial_stderr:
            stderr = partial_stderr
        stdout = stdout_prefix + stdout
        stderr = stderr_prefix + stderr
        raise AssertionError(
            f"real GTK4 probe timed out after {timeout}s\n"
            + format_output(stdout, stderr)
        )
    return stdout_prefix + stdout, stderr_prefix + stderr


def wait_for_ready(child, timeout):
    """Wait for the Lua probe's first completed DrawingArea onDraw callback."""
    deadline = time.monotonic() + timeout
    stdout = bytearray()
    stderr = bytearray()
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ, stdout)
    selector.register(child.stderr, selectors.EVENT_READ, stderr)
    try:
        while time.monotonic() < deadline:
            if READY_MARKER in stdout:
                return bytes(stdout), bytes(stderr)
            remaining = max(0.0, deadline - time.monotonic())
            events = selector.select(min(0.2, remaining))
            for key, _ in events:
                chunk = os.read(key.fileobj.fileno(), 4096)
                if chunk:
                    key.data.extend(chunk)
                else:
                    try:
                        selector.unregister(key.fileobj)
                    except KeyError:
                        pass
            if READY_MARKER in stdout:
                return bytes(stdout), bytes(stderr)
            if child.poll() is not None and not selector.get_map():
                break
    finally:
        selector.close()

    stdout_full, stderr_full = kill_and_collect(
        child, bytes(stdout), bytes(stderr)
    )
    if child.returncode is not None and time.monotonic() < deadline:
        raise AssertionError(
            f"real GTK4 probe exited before readiness (exit {child.returncode})\n"
            + format_output(stdout_full, stderr_full)
        )
    raise AssertionError(
        f"real GTK4 probe did not report readiness within {timeout}s\n"
        + format_output(stdout_full, stderr_full)
    )

def load_x11():
    x11_name = ctypes.util.find_library("X11")
    xtst_name = ctypes.util.find_library("Xtst")
    if not x11_name or not xtst_name:
        return None
    try:
        x11 = ctypes.CDLL(x11_name)
        xtst = ctypes.CDLL(xtst_name)
    except OSError:
        return None

    display_p = ctypes.c_void_p
    window_t = ctypes.c_ulong
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = display_p
    x11.XCloseDisplay.argtypes = [display_p]
    x11.XCloseDisplay.restype = ctypes.c_int
    x11.XDefaultRootWindow.argtypes = [display_p]
    x11.XDefaultRootWindow.restype = window_t
    x11.XQueryTree.argtypes = [
        display_p, window_t,
        ctypes.POINTER(window_t), ctypes.POINTER(window_t),
        ctypes.POINTER(ctypes.POINTER(window_t)), ctypes.POINTER(ctypes.c_uint),
    ]
    x11.XQueryTree.restype = ctypes.c_int
    x11.XFetchName.argtypes = [display_p, window_t, ctypes.POINTER(ctypes.c_char_p)]
    x11.XFetchName.restype = ctypes.c_int
    x11.XFree.argtypes = [ctypes.c_void_p]
    x11.XFree.restype = ctypes.c_int
    x11.XGetGeometry.argtypes = [
        display_p, window_t, ctypes.POINTER(window_t),
        ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint),
        ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint),
    ]
    x11.XGetGeometry.restype = ctypes.c_int
    x11.XTranslateCoordinates.argtypes = [
        display_p, window_t, window_t, ctypes.c_int, ctypes.c_int,
        ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(window_t),
    ]
    x11.XTranslateCoordinates.restype = ctypes.c_int
    x11.XFlush.argtypes = [display_p]
    x11.XFlush.restype = ctypes.c_int

    xtst.XTestFakeMotionEvent.argtypes = [display_p, ctypes.c_int, ctypes.c_int,
                                          ctypes.c_int, ctypes.c_ulong]
    xtst.XTestFakeMotionEvent.restype = ctypes.c_int
    xtst.XTestFakeButtonEvent.argtypes = [display_p, ctypes.c_uint, ctypes.c_int,
                                          ctypes.c_ulong]
    xtst.XTestFakeButtonEvent.restype = ctypes.c_int
    return x11, xtst


def find_window(x11, display, target):
    root = x11.XDefaultRootWindow(display)
    seen = set()

    def visit(window):
        if int(window) in seen:
            return None
        seen.add(int(window))
        name = ctypes.c_char_p()
        if x11.XFetchName(display, window, ctypes.byref(name)) and name.value:
            try:
                title = name.value.decode("utf-8", "replace")
            finally:
                x11.XFree(name)
            if title == target:
                return window

        returned_root = ctypes.c_ulong()
        parent = ctypes.c_ulong()
        children = ctypes.POINTER(ctypes.c_ulong)()
        count = ctypes.c_uint()
        if not x11.XQueryTree(display, window, ctypes.byref(returned_root),
                              ctypes.byref(parent), ctypes.byref(children),
                              ctypes.byref(count)):
            return None
        try:
            for index in range(count.value):
                found = visit(children[index])
                if found is not None:
                    return found
        finally:
            if children:
                x11.XFree(children)
        return None

    return visit(root)


def click_center_twice(x11, xtst, display, window):
    root_return = ctypes.c_ulong()
    x = ctypes.c_int()
    y = ctypes.c_int()
    width = ctypes.c_uint()
    height = ctypes.c_uint()
    border = ctypes.c_uint()
    depth = ctypes.c_uint()
    if not x11.XGetGeometry(display, window, ctypes.byref(root_return),
                            ctypes.byref(x), ctypes.byref(y), ctypes.byref(width),
                            ctypes.byref(height), ctypes.byref(border),
                            ctypes.byref(depth)):
        raise AssertionError("XGetGeometry failed for GTK probe window")

    root = x11.XDefaultRootWindow(display)
    root_x = ctypes.c_int()
    root_y = ctypes.c_int()
    child = ctypes.c_ulong()
    if not x11.XTranslateCoordinates(display, window, root, 0, 0,
                                     ctypes.byref(root_x), ctypes.byref(root_y),
                                     ctypes.byref(child)):
        raise AssertionError("XTranslateCoordinates failed for GTK probe window")

    px = root_x.value + max(1, width.value // 2)
    py = root_y.value + max(1, height.value // 2)
    if not xtst.XTestFakeMotionEvent(display, -1, px, py, 0):
        raise AssertionError("XTestFakeMotionEvent failed")
    for _ in range(2):
        if not xtst.XTestFakeButtonEvent(display, 1, 1, 0):
            raise AssertionError("XTestFakeButtonEvent press failed")
        if not xtst.XTestFakeButtonEvent(display, 1, 0, 0):
            raise AssertionError("XTestFakeButtonEvent release failed")
        x11.XFlush(display)
        time.sleep(0.06)
    x11.XFlush(display)


def start_xvfb(xvfb):
    # Use a private display without relying on xvfb-run so the parent process can
    # inject XTest events into the same server.
    for number in range(90, 120):
        socket_path = Path(f"/tmp/.X11-unix/X{number}")
        if socket_path.exists():
            continue
        display = f":{number}"
        process = subprocess.Popen(
            [xvfb, display, "-screen", "0", "1024x768x24", "-nolisten", "tcp"],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        for _ in range(50):
            if process.poll() is not None:
                break
            if socket_path.exists():
                return process, display
            time.sleep(0.04)
        stderr = b""
        if process.poll() is not None and process.stderr:
            stderr = process.stderr.read()[-1000:]
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
        if stderr:
            continue
    return None, None


def main():
    if len(sys.argv) != 2:
        raise AssertionError("usage: python3 tools/test_gui_real_gtk.py /path/to/babet")
    binary = str(Path(sys.argv[1]).resolve())
    xvfb = shutil.which("Xvfb")
    if not xvfb:
        return skip("Xvfb is unavailable")
    try:
        ctypes.CDLL("libgtk-4.so.1")
    except OSError:
        return skip("libgtk-4.so.1 is unavailable")
    libraries = load_x11()
    if libraries is None:
        return skip("X11/XTest runtime libraries are unavailable")
    x11, xtst = libraries

    xvfb_process, display_name = start_xvfb(xvfb)
    if xvfb_process is None:
        return skip("cannot start a private Xvfb server")

    env = dict(os.environ)
    # Never let a fake GTK from another regression leak into this probe.
    env.pop("LD_LIBRARY_PATH", None)
    for key in list(env):
        if key.startswith("BABET_FAKE_GTK") or key.startswith("BABET_CAIRO_"):
            env.pop(key, None)
    env["DISPLAY"] = display_name
    env["GDK_BACKEND"] = "x11"
    env["G_DEBUG"] = "fatal-criticals"

    # When this optional integration probe is launched from Babet's ASan build,
    # LeakSanitizer also audits the dynamically loaded *system* GTK/Pango/Cairo/
    # fontconfig stack. Those libraries intentionally keep process-global caches
    # alive until exit and can therefore report large third-party leak sets even
    # after the Babet contract has completed successfully. Disable only leak
    # detection for this child: AddressSanitizer's invalid-access/UAF checks and
    # UBSan remain active, while Babet-owned leak coverage stays enabled in the
    # hermetic sanitizer regressions.
    asan_options = env.get("ASAN_OPTIONS", "")
    leak_option = "detect_leaks=0"
    env["ASAN_OPTIONS"] = (
        f"{asan_options}:{leak_option}" if asan_options else leak_option
    )

    child = None
    display = None
    stdout_prefix = b""
    stderr_prefix = b""
    try:
        # Wait until Xlib can actually connect to the new server.
        for _ in range(50):
            display = x11.XOpenDisplay(display_name.encode())
            if display:
                break
            time.sleep(0.04)
        if not display:
            return skip("Xlib cannot connect to the private Xvfb server")

        child = subprocess.Popen(
            [binary, str(ROOT / "tests/gui/real_gtk_contract.lua")],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
        )

        # The X11 window can become discoverable before GTK has completed its
        # first frame and started servicing pointer events. Synchronize on the
        # first DrawingArea onDraw instead of racing against window discovery.
        stdout_prefix, stderr_prefix = wait_for_ready(child, 20)

        window = None
        for _ in range(150):
            if child.poll() is not None:
                break
            window = find_window(x11, display, WINDOW_TITLE)
            if window is not None:
                break
            time.sleep(0.04)

        if window is None:
            stdout, stderr = kill_and_collect(
                child, stdout_prefix, stderr_prefix
            )
            combined = decode(stdout + b"\n" + stderr)
            if ("no usable graphical display" in combined
                    or "cannot open display" in combined.lower()):
                return skip("GTK4 is installed but its X11 backend is unavailable")
            raise AssertionError(
                "real GTK4 probe window did not appear after readiness\n"
                + format_output(stdout, stderr)
            )

        click_center_twice(x11, xtst, display, window)
        stdout, stderr = finish_with_timeout(
            child, 20, stdout_prefix, stderr_prefix
        )
        stdout_text = decode(stdout)
        if child.returncode == 0 and "REAL_GTK_CONTRACT_OK" in stdout_text:
            print("[PASS] real GTK4: containers, Entry coalescing, SpinButton, Calendar and CSS")
            print("[PASS] real GTK4: DrawingArea Cairo draw and real double-click n_press")
            print("real GTK4 regression: 2 PASS / 0 FAIL")
            return 0
        raise AssertionError(
            f"real GTK4 probe failed with exit {child.returncode}\n"
            + format_output(stdout, stderr)
        )
    finally:
        if display:
            x11.XCloseDisplay(display)
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=2)
        xvfb_process.terminate()
        try:
            xvfb_process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            xvfb_process.kill()
            xvfb_process.wait(timeout=2)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"[FAIL] real GTK4 regression: {error}", file=sys.stderr)
        sys.exit(1)
