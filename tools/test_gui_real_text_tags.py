#!/usr/bin/env python3
"""Optional real GTK UTF-8 tags and mapped, insensitive TextView hit testing."""
import ctypes
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import test_gui_real_gtk as native
from test_gui_files import ROOT
from test_gui_real_files import probe_environment


def run_probes(binary, env, x11, xtst, display):
    with tempfile.TemporaryDirectory(prefix='babet_gui_tags_') as tmp:
        env=probe_environment(env,Path(tmp))
        result=subprocess.run([binary,str(ROOT/'tests/gui/text_tags_contract.lua'),'real'],env=env,capture_output=True,timeout=20)
        assert result.returncode==0 and b'TEXT_TAGS_OK' in result.stdout,native.format_output(result.stdout,result.stderr)
        print('[PASS] real GTK TextView tags UTF-8, properties and ranges')
        child=subprocess.Popen([binary,str(ROOT/'tests/gui/real_gtk_text_tags.lua')],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        out=err=b''
        try:
            out,err=native.wait_for_ready(child,20,marker=b'REAL_TAGS_READY')
            window=native.find_window(x11,display,'Babet text tags probe')
            assert window,'mapped TextView window not found'
            x11.XSetInputFocus(display,window,2,0);x11.XFlush(display)
            native.inject_keysym(x11,xtst,display,0xff1b)
            out,err=native.finish_with_timeout(child,10,out,err)
            assert child.returncode==0 and b'REAL_TAGS_OK' in out,native.format_output(out,err)
            print('[PASS] real GTK insensitive TextView geometry and byte offsets')
        except BaseException as failure:
            if child.poll() is None:out,err=native.kill_and_collect(child,out,err)
            raise AssertionError(str(failure)+'\n'+native.format_output(out,err)) from failure
    print('Real GTK TextView tags: 2 PASS / 0 FAIL')


def main():
    binary = str(Path(sys.argv[1]).resolve())
    xvfb = shutil.which('Xvfb')
    if not xvfb:
        return native.skip('Xvfb unavailable (TextView tags)')
    try:
        ctypes.CDLL('libgtk-4.so.1')
    except OSError:
        return native.skip('GTK4 unavailable (TextView tags)')
    libraries = native.load_x11()
    if not libraries:
        return native.skip('X11/XTest unavailable (TextView tags)')
    x11, xtst = libraries
    server, name = native.start_xvfb(xvfb)
    if not server:
        return native.skip('private Xvfb unavailable (TextView tags)')
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
        print('[FAIL] real GTK TextView tags:', e, file=sys.stderr)
        sys.exit(1)
