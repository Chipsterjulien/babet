#!/usr/bin/env python3
"""Optional native PNG/JPEG sizing and GTK4.10 file-dialog integration."""
import ctypes
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import test_gui_real_gtk as native
from test_gui_files import png_bytes, ROOT


def probe_environment(environ, folder):
    """Keep GtkFileDialog on Xvfb instead of using the desktop session portal.

    GTK_USE_PORTAL=0 does not disable GtkFileDialog's preferred portal path.
    Disable portals explicitly and prevent session-bus discovery/autolaunch.
    These overrides affect only test children, never the Babet runtime.
    """
    env = dict(environ)
    for key in list(env):
        if (key.startswith(('BABET_FAKE_GTK', 'BABET_CAIRO_', 'DBUS_'))
                or key in ('WAYLAND_DISPLAY', 'GTK_USE_PORTAL', 'GTK_DEBUG',
                           'GSK_DEBUG', 'DESKTOP_STARTUP_ID', 'XDG_ACTIVATION_TOKEN')):
            env.pop(key, None)
    env.update(GDK_BACKEND='x11', GDK_DEBUG='no-portals', GSK_RENDERER='cairo',
               G_DEBUG='fatal-criticals', GTK_A11Y='none', GIO_USE_VFS='local',
               LC_ALL='C.UTF-8', LANGUAGE='C', GSETTINGS_BACKEND='memory',
               DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(folder / 'no-session-bus'))
    # Keep chooser preferences, recent files and thumbnails out of the real
    # desktop directories. All of these paths disappear after the test.
    for key, name in [('XDG_CONFIG_HOME', 'config'), ('XDG_DATA_HOME', 'data'),
                      ('XDG_CACHE_HOME', 'cache'), ('XDG_STATE_HOME', 'state')]:
        directory = folder / name
        directory.mkdir()
        env[key] = str(directory)
    return env


def chord(x11, xtst, display, modifier, key):
    code = x11.XKeysymToKeycode(display, modifier)
    assert code and xtst.XTestFakeKeyEvent(display, code, 1, 0)
    try:
        native.inject_keysym(x11, xtst, display, key)
    finally:
        xtst.XTestFakeKeyEvent(display, code, 0, 0)
        x11.XFlush(display)


def run_probes(binary, env, x11, xtst, display):
    passed = skipped = 0
    with tempfile.TemporaryDirectory(prefix='babet_gui_files_') as tmp:
        folder = Path(tmp)
        env = probe_environment(env, folder)
        (folder / 'image.png').write_bytes(png_bytes())
        for mode in ['picture', 'open', 'multiple', 'save', 'cancel']:
            if mode == 'picture':
                args = [str(ROOT / 'tests/gui/real_gtk_picture.lua'),
                        str(folder / 'image.png'), str(ROOT / 'tests/gui/fixtures/picture.jpg')]
            else:
                args = [str(ROOT / 'tests/gui/real_gtk_file_dialog.lua'), mode, tmp]
            child = subprocess.Popen([binary, *args], env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            out = err = b''
            try:
                out, err = native.wait_for_ready(child, 15, marker=b'REAL_FILES_')
                if b'REAL_FILES_SKIP:' in out:
                    out, err = native.finish_with_timeout(child, 5, out, err)
                    assert child.returncode == 0, native.format_output(out, err)
                    print('[SKIP] real files ' + mode + ': ' + native.decode(out).strip())
                    skipped += 1
                    continue
                title = 'Babet picture probe' if mode == 'picture' else 'Babet file probe'
                deadline = time.monotonic() + 10
                window = None
                while time.monotonic() < deadline:
                    window = native.find_window(x11, display, title)
                    if window or child.poll() is not None:
                        break
                    time.sleep(.04)
                assert window, ('native file/picture window was not found on '
                                + env.get('DISPLAY', '<unset>')
                                + ' (desktop portal disabled, isolated session bus)')
                time.sleep(.4)  # initial directory enumeration/layout
                x11.XSetInputFocus(display, window, 2, 0)
                x11.XFlush(display)
                if mode in ['picture', 'cancel']:
                    native.inject_keysym(x11, xtst, display, 0xff1b)
                elif mode == 'save':
                    chord(x11, xtst, display, 0xffe9, ord('s'))
                else:
                    chord(x11, xtst, display, 0xffe3, ord('l'))
                    time.sleep(.1)
                    for c in str(folder / 'image.png'):
                        if c == '_':
                            chord(x11, xtst, display, 0xffe1, ord('-'))
                        else:
                            native.inject_keysym(x11, xtst, display, ord(c))
                    native.inject_keysym(x11, xtst, display, 0xff0d)
                out, err = native.finish_with_timeout(child, 15, out, err)
                assert child.returncode == 0 and ('REAL_FILES_OK:' + mode).encode() in out, native.format_output(out, err)
                print('[PASS] real GTK files ' + mode)
                passed += 1
            except BaseException as failure:
                if child.poll() is None:
                    out, err = native.kill_and_collect(child, out, err)
                raise AssertionError(mode + ': ' + str(failure) + '\n' + native.format_output(out, err)) from failure
        assert not (folder / 'saved.png').exists(), 'saveFile must only select a path'
    print(f'Real GTK files: {passed} PASS / {skipped} SKIP')


def main():
    binary = str(Path(sys.argv[1]).resolve())
    xvfb = shutil.which('Xvfb')
    if not xvfb:
        return native.skip('Xvfb unavailable (pictures/files)')
    try:
        ctypes.CDLL('libgtk-4.so.1')
    except OSError:
        return native.skip('GTK4 unavailable (pictures/files)')
    libraries = native.load_x11()
    if not libraries:
        return native.skip('X11/XTest unavailable (pictures/files)')
    x11, xtst = libraries
    server, name = native.start_xvfb(xvfb)
    if not server:
        return native.skip('private Xvfb unavailable (pictures/files)')
    display = None
    try:
        for _ in range(50):
            display = x11.XOpenDisplay(name.encode())
            if display:
                break
            time.sleep(.04)
        if not display:
            raise AssertionError('cannot connect to Xvfb')
        env = dict(os.environ)
        env.pop('LD_LIBRARY_PATH', None)
        env['DISPLAY'] = name
        # Same third-party cache policy as the existing real-GTK regression.
        env['ASAN_OPTIONS'] = env.get('ASAN_OPTIONS', '') + ':detect_leaks=0'
        run_probes(binary, env, x11, xtst, display)
    finally:
        if display:
            x11.XCloseDisplay(display)
        server.terminate()
        try:
            server.wait(timeout=2)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()


if __name__ == '__main__':
    try:
        sys.exit(main() or 0)
    except Exception as e:
        print('[FAIL] real GTK files:', e, file=sys.stderr)
        sys.exit(1)
