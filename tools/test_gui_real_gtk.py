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


def wait_for_ready(child, timeout, marker=READY_MARKER):
    """Wait for the probe readiness marker (default: legacy GTK probe)."""
    deadline = time.monotonic() + timeout
    stdout = bytearray()
    stderr = bytearray()
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ, stdout)
    selector.register(child.stderr, selectors.EVENT_READ, stderr)
    try:
        while time.monotonic() < deadline:
            if marker in stdout:
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
            if marker in stdout:
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
    x11.XKeysymToKeycode.argtypes = [display_p, ctypes.c_ulong]
    x11.XKeysymToKeycode.restype = ctypes.c_ubyte
    x11.XSetInputFocus.argtypes = [display_p, window_t, ctypes.c_int, ctypes.c_ulong]
    x11.XSetInputFocus.restype = ctypes.c_int
    xtst.XTestFakeKeyEvent.argtypes = [display_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
    xtst.XTestFakeKeyEvent.restype = ctypes.c_int
    x11.XFlush.argtypes = [display_p]
    x11.XFlush.restype = ctypes.c_int
    x11.XGetImage.argtypes = [display_p, window_t, ctypes.c_int, ctypes.c_int,
                              ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_int]
    x11.XGetImage.restype = ctypes.c_void_p
    x11.XGetPixel.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
    x11.XGetPixel.restype = ctypes.c_ulong
    x11.XDestroyImage.argtypes = [ctypes.c_void_p]
    x11.XDestroyImage.restype = ctypes.c_int

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


def click_center(x11, xtst, display, window, count=2):
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
    for _ in range(count):
        if not xtst.XTestFakeButtonEvent(display, 1, 1, 0):
            raise AssertionError("XTestFakeButtonEvent press failed")
        if not xtst.XTestFakeButtonEvent(display, 1, 0, 0):
            raise AssertionError("XTestFakeButtonEvent release failed")
        x11.XFlush(display)
        time.sleep(0.06)
    x11.XFlush(display)


def check_drag_icon(x11, display, x, y, mode):
    """Inspect the actual 24-bit Xvfb pixels under the held drag, not setters.

    The fixture uses a red source, green preview and blue target. The sample
    is beside the pointer over the target, away from the original widgets.
    A blank paintable cannot pass this check merely by completing the drop.
    """
    expected = 0x00ff00 if mode == "mapped" else 0xff0000
    root = x11.XDefaultRootWindow(display)
    deadline = time.monotonic() + 2
    matches = 0
    while time.monotonic() < deadline:
        snapshot = x11.XGetImage(display, root, x + 15, y + 5,
                                 80, 25, ctypes.c_ulong(-1).value, 2)  # ZPixmap
        if not snapshot:
            raise AssertionError("cannot capture native drag icon")
        try:
            matches = sum((x11.XGetPixel(snapshot, px, py) & 0xffffff) == expected
                          for px in range(0, 80, 4) for py in range(0, 25, 4))
        finally:
            x11.XDestroyImage(snapshot)
        if matches >= 50:
            return
        time.sleep(0.04)  # wait for the icon's next GTK frame
    raise AssertionError(f"native drag icon {mode}: expected colour {expected:#08x}, only {matches} pixels")


def drag_across_window(x11, xtst, display, window, icon_mode=None):
    """Drag from the left half to the right half of one GTK probe window."""
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
        raise AssertionError("XGetGeometry failed for GTK DND window")
    root = x11.XDefaultRootWindow(display)
    root_x = ctypes.c_int()
    root_y = ctypes.c_int()
    child = ctypes.c_ulong()
    if not x11.XTranslateCoordinates(display, window, root, 0, 0,
                                     ctypes.byref(root_x), ctypes.byref(root_y),
                                     ctypes.byref(child)):
        raise AssertionError("XTranslateCoordinates failed for GTK DND window")

    start_x = root_x.value + max(10, width.value // 5)
    end_x = root_x.value + max(20, (width.value * 4) // 5)
    py = root_y.value + max(10, height.value // 2)
    if not xtst.XTestFakeMotionEvent(display, -1, start_x, py, 0):
        raise AssertionError("XTest DND initial motion failed")
    if not xtst.XTestFakeButtonEvent(display, 1, 1, 0):
        raise AssertionError("XTest DND press failed")
    x11.XFlush(display)
    time.sleep(0.08)
    try:
        for step in range(1, 11):
            px = start_x + ((end_x - start_x) * step) // 10
            if not xtst.XTestFakeMotionEvent(display, -1, px, py, 0):
                raise AssertionError("XTest DND motion failed")
            x11.XFlush(display)
            time.sleep(0.04)
        if icon_mode is not None:
            check_drag_icon(x11, display, end_x, py, icon_mode)
    finally:
        released = xtst.XTestFakeButtonEvent(display, 1, 0, 0)
        x11.XFlush(display)
    if not released:
        raise AssertionError("XTest DND release failed")


def calendar_key(x11, xtst, display, keysym):
    """Inject Ctrl+arrow; release both keys even if event injection fails."""
    control = x11.XKeysymToKeycode(display, 0xffe3)  # Control_L
    arrow = x11.XKeysymToKeycode(display, keysym)
    if not control or not arrow:
        raise AssertionError("X11 keymap lacks Calendar navigation keys")
    try:
        if not xtst.XTestFakeKeyEvent(display, control, 1, 0):
            raise AssertionError("XTest Control press failed")
        if not xtst.XTestFakeKeyEvent(display, arrow, 1, 0):
            raise AssertionError("XTest Calendar arrow press failed")
    finally:
        arrow_released = xtst.XTestFakeKeyEvent(display, arrow, 0, 0)
        control_released = xtst.XTestFakeKeyEvent(display, control, 0, 0)
        x11.XFlush(display)
    if not arrow_released or not control_released:
        raise AssertionError("XTest Calendar key release failed")


def inject_keysym(x11, xtst, display, keysym):
    """Inject one key press/release pair through XTest."""
    keycode = x11.XKeysymToKeycode(display, keysym)
    if not keycode:
        raise AssertionError(f"X11 keymap lacks keysym 0x{keysym:x}")
    pressed = xtst.XTestFakeKeyEvent(display, keycode, 1, 0)
    released = xtst.XTestFakeKeyEvent(display, keycode, 0, 0)
    x11.XFlush(display)
    if not pressed or not released:
        raise AssertionError("XTest key injection failed")


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
    passed = []

    def success(message):
        passed.append(message)
        print(f"[PASS] real GTK4: {message}")

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

        click_center(x11, xtst, display, window)
        stdout, stderr = finish_with_timeout(
            child, 20, stdout_prefix, stderr_prefix
        )
        stdout_text = decode(stdout)
        if child.returncode != 0 or "REAL_GTK_CONTRACT_OK" not in stdout_text:
            raise AssertionError(
                f"real GTK4 probe failed with exit {child.returncode}\n"
                + format_output(stdout, stderr)
            )
        success("containers, Entry coalescing, SpinButton, Calendar and CSS")
        success("DrawingArea Cairo draw and real double-click n_press")

        # GtkLabel height-for-width behavior used by free-positioned notes.
        # The Lua probe reports readiness only from its first onDraw, proving
        # the initial three-line height before any input. A real click then
        # widens the note and the next draw must observe two lines.
        child = subprocess.Popen(
            [binary, str(ROOT / "tests/gui/real_gtk_label_wrap.lua")],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
        )
        wrap_out, wrap_err = wait_for_ready(
            child, 20, marker=b"REAL_GTK_LABEL_WRAP_READY\n"
        )
        wrap_window = None
        for _ in range(150):
            if child.poll() is not None:
                break
            wrap_window = find_window(x11, display, "Babet real GTK label wrap probe")
            if wrap_window is not None:
                break
            time.sleep(0.04)
        if wrap_window is None:
            stdout, stderr = kill_and_collect(child, wrap_out, wrap_err)
            raise AssertionError("GtkLabel wrap probe window not found\n" + format_output(stdout, stderr))
        click_center(x11, xtst, display, wrap_window, count=1)
        stdout, stderr = finish_with_timeout(child, 20, wrap_out, wrap_err)
        if child.returncode != 0 or "REAL_GTK_LABEL_WRAP_OK" not in decode(stdout):
            raise AssertionError(
                f"real GTK4 GtkLabel wrap failed with exit {child.returncode}\n"
                + format_output(stdout, stderr)
            )
        success("GtkLabel first-frame wrapping and height-for-width relayout")

        # Independent native GtkProgressBar gesture. The main GTK probe has
        # already exited; reuse the same private Xvfb server and input helper.
        child = subprocess.Popen(
            [binary, str(ROOT / "tests/gui/real_gtk_progress.lua")],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
        )
        progress_out, progress_err = wait_for_ready(
            child, 20, marker=b"REAL_GTK_PROGRESS_READY\n"
        )
        progress_window = None
        for _ in range(150):
            if child.poll() is not None:
                break
            progress_window = find_window(x11, display, "Babet real GTK progress probe")
            if progress_window is not None:
                break
            time.sleep(0.04)
        if progress_window is None:
            stdout, stderr = kill_and_collect(child, progress_out, progress_err)
            raise AssertionError("native progress window not found\n" + format_output(stdout, stderr))
        # The window may be mapped before its first layout; let GTK draw the
        # progress widget before injecting the four primary-button clicks.
        time.sleep(0.25)
        click_center(x11, xtst, display, progress_window, count=4)
        stdout, stderr = finish_with_timeout(child, 8, progress_out, progress_err)
        if child.returncode != 0 or "REAL_GTK_PROGRESS_OK" not in decode(stdout):
            raise AssertionError(
                f"real GTK4 progress failed with exit {child.returncode}\n"
                + format_output(stdout, stderr)
            )
        success("progressBar receives four real primary clicks")
        # The same ownership probes run on both the simulator and real GTK.
        for mode in ("cycles", "lifetime"):
            child = subprocess.Popen(
                [binary, str(ROOT / "tests/gui/popover_ownership.lua"), mode],
                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                stdin=subprocess.DEVNULL,
            )
            stdout, stderr = finish_with_timeout(child, 8)
            if child.returncode != 0 or f"GUI_POPOVER_OWNERSHIP_OK:{mode}" not in decode(stdout):
                raise AssertionError(f"real GTK popover {mode} failed\n" + format_output(stdout, stderr))
            if b"still has children left" in stderr:
                raise AssertionError(format_output(stdout, stderr))
            success(f"popover ownership: {mode}")

        # Native GTK4 DND: real GtkDragSource/GtkDropTarget with an XTest drag.
        dnd_cases = [("real_gtk_dnd.lua", mode) for mode in (
            "normal", "disabled-child", "reenabled-child", "self-disable-enter",
            "self-disable-drop", "clear-source", "close-drop", "nested-hover-false",
            "nested-drop-false", "remove-source", "copy-action")]
        dnd_cases += [("native_dnd_actions.lua", mode) for mode in (
            "copy-at-drop", "move-at-drop", "copy", "move", "link", "copy-only", "link-only", "drop-false", "drop-error", "reject-then-move")]
        dnd_cases += [("native_dnd_icon.lua", mode) for mode in (
            "unparented", "mapped", "hidden", "detached", "destroyed", "reset")]
        for fixture, mode in dnd_cases:
            child = subprocess.Popen(
                [binary, str(ROOT / "tests/gui" / fixture), mode],
                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                stdin=subprocess.DEVNULL,
            )
            dnd_out, dnd_err = wait_for_ready(
                child, 20, marker=b"REAL_GTK_DND_READY\n"
            )
            dnd_window = None
            for _ in range(150):
                if child.poll() is not None:
                    break
                dnd_window = find_window(x11, display, "Babet real GTK DND probe")
                if dnd_window is not None:
                    break
                time.sleep(0.04)
            if dnd_window is None:
                stdout, stderr = kill_and_collect(child, dnd_out, dnd_err)
                raise AssertionError("native DND window not found\n" + format_output(stdout, stderr))
            time.sleep(0.25)
            is_icon_probe = fixture == "native_dnd_icon.lua"
            drag_across_window(x11, xtst, display, dnd_window,
                               icon_mode=mode if is_icon_probe else None)
            if mode == "reject-then-move":
                again_out, again_err = wait_for_ready(child, 8, marker=b"REAL_GTK_DND_AGAIN\n")
                dnd_out += again_out
                dnd_err += again_err
                drag_across_window(x11, xtst, display, dnd_window)
            stdout, stderr = finish_with_timeout(child, 8, dnd_out, dnd_err)
            marker = f"GUI_DND_ICON_OK:{mode}" if is_icon_probe else f"REAL_GTK_DND_OK:{mode}"
            if child.returncode != 0 or marker not in decode(stdout):
                raise AssertionError(
                    f"real GTK4 DND failed with exit {child.returncode}\n"
                    + format_output(stdout, stderr)
                )
            if mode in ("copy-at-drop", "move-at-drop"):
                assert "cannot change the negotiated action during drop" in decode(stderr), decode(stderr)
            if fixture == "native_dnd_actions.lua" and mode == "drop-error":
                assert "DND_FINAL_ERROR_SENTINEL" in decode(stderr), decode(stderr)
            success(f"native DND visible icon: {mode}" if is_icon_probe else f"native DND lifetime and propagation: {mode}")

        # Desktop application primitives: real GtkPaned, context GtkPopover,
        # generic pointer/key controllers, geometry translation and modal window.
        child = subprocess.Popen(
            [binary, str(ROOT / "tests/gui/real_gtk_desktop.lua")],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
        )
        desktop_out, desktop_err = wait_for_ready(
            child, 20, marker=b"REAL_GTK_DESKTOP_READY\n"
        )
        desktop_window = None
        for _ in range(150):
            if child.poll() is not None:
                break
            desktop_window = find_window(x11, display, "Babet real GTK desktop probe")
            if desktop_window is not None:
                break
            time.sleep(0.04)
        if desktop_window is None:
            stdout, stderr = kill_and_collect(child, desktop_out, desktop_err)
            raise AssertionError("desktop primitive window not found\n" + format_output(stdout, stderr))
        time.sleep(0.25)
        click_center(x11, xtst, display, desktop_window, count=1)
        # Do not race the key injection against GTK's delivery of the pointer
        # event.  ASan/UBSan can make the first event dispatch noticeably
        # slower even after the X11 window is mapped.  Wait for an explicit
        # acknowledgement from the Lua pointer callback instead of sleeping.
        pointer_out, pointer_err = wait_for_ready(
            child, 20, marker=b"REAL_GTK_DESKTOP_POINTER_OK\n"
        )
        desktop_out += pointer_out
        desktop_err += pointer_err
        x11.XSetInputFocus(display, desktop_window, 2, 0)
        inject_keysym(x11, xtst, display, 0xff1b)  # Escape
        stdout, stderr = finish_with_timeout(child, 20, desktop_out, desktop_err)
        if child.returncode != 0 or "REAL_GTK_DESKTOP_OK" not in decode(stdout):
            raise AssertionError(
                f"real GTK4 desktop primitives failed with exit {child.returncode}\n"
                + format_output(stdout, stderr)
            )
        success("Paned, context popover, pointer/key input and geometry primitives")

        # Exercise visible popup/popdown independently of the desktop key
        # probe. Wait for a real popup draw before activating its close button;
        # an immediate popup/popdown in one callback can swallow GTK's next key.
        child = subprocess.Popen(
            [binary, str(ROOT / "tests/gui/real_gtk_popover.lua")],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
        )
        popover_out, popover_err = wait_for_ready(
            child, 20, marker=b"REAL_GTK_POPOVER_READY\n"
        )
        popover_window = find_window(x11, display, "Babet real GTK popover probe")
        if popover_window is None:
            stdout, stderr = kill_and_collect(child, popover_out, popover_err)
            raise AssertionError("popover probe window not found\n" + format_output(stdout, stderr))
        x11.XSetInputFocus(display, popover_window, 2, 0)
        click_center(x11, xtst, display, popover_window, count=1)
        drawn_out, drawn_err = wait_for_ready(
            child, 20, marker=b"REAL_GTK_POPOVER_DRAWN\n"
        )
        popover_out += drawn_out
        popover_err += drawn_err
        inject_keysym(x11, xtst, display, 0x20)  # Space activates focused close button
        stdout, stderr = finish_with_timeout(child, 20, popover_out, popover_err)
        if child.returncode != 0 or "REAL_GTK_POPOVER_OK" not in decode(stdout):
            raise AssertionError(
                f"real GTK4 visible popover failed with exit {child.returncode}\n"
                + format_output(stdout, stderr)
            )
        success("context popover is drawn before a separate event closes it")

        # A separate Calendar window verifies real navigation. The four native
        # signals are reached through GTK's Ctrl+arrow key bindings, not setters
        # or direct signal emission. Wait for an acknowledgement after each key.
        child = subprocess.Popen(
            [binary, str(ROOT / "tests/gui/real_gtk_calendar.lua")],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
        )
        calendar_out, calendar_err = wait_for_ready(
            child, 20, marker=b"REAL_GTK_CALENDAR_READY\n"
        )
        calendar_window = find_window(x11, display, "Babet real GTK calendar probe")
        if calendar_window is None:
            stdout, stderr = kill_and_collect(child, calendar_out, calendar_err)
            raise AssertionError("native Calendar window not found\n" + format_output(stdout, stderr))
        x11.XSetInputFocus(display, calendar_window, 2, 0)  # RevertToParent, CurrentTime
        click_center(x11, xtst, display, calendar_window, count=1)
        chunk_out, chunk_err = wait_for_ready(child, 8, marker=b"REAL_GTK_CALENDAR_FOCUSED\n")
        calendar_out += chunk_out
        calendar_err += chunk_err
        # Right, Left, Down, Up, Left, Right: all four signals, leap-day clamp
        # and December/January rollover. The final callback closes its window.
        for step, keysym in enumerate((0xff53, 0xff51, 0xff54, 0xff52, 0xff51, 0xff53), 1):
            calendar_key(x11, xtst, display, keysym)
            chunk_out, chunk_err = wait_for_ready(
                child, 8, marker=f"REAL_GTK_CALENDAR_STEP_{step}\n".encode()
            )
            calendar_out += chunk_out
            calendar_err += chunk_err
        stdout, stderr = finish_with_timeout(child, 8, calendar_out, calendar_err)
        if child.returncode != 0 or "REAL_GTK_CALENDAR_OK" not in decode(stdout):
            raise AssertionError(
                f"real GTK4 Calendar failed with exit {child.returncode}\n"
                + format_output(stdout, stderr)
            )
        success("Calendar month/year navigation, markers and callback close")
        print(f"real GTK4 regression: {len(passed)} PASS / 0 FAIL")
        return 0
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
