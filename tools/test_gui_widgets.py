#!/usr/bin/env python3
"""GUI lots 3-6 contracts using a fake GTK DSO; no GTK headers/display required."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(command, env=None):
    result = subprocess.run(command, env=env, text=True, capture_output=True,
                            stdin=subprocess.DEVNULL, timeout=60)
    if result.returncode:
        raise AssertionError(f"{command!r}: exit {result.returncode}\n"
                             f"{result.stdout[-5000:]}\n{result.stderr[-8000:]}")
    return result


def main():
    if len(sys.argv) != 2:
        raise AssertionError("usage: python3 tools/test_gui_widgets.py /path/to/babet")
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="babet-gui-widgets-") as directory:
        temp = Path(directory)
        lib = temp / "lib"
        lib.mkdir()
        run([*shlex.split(os.environ.get("CC", "cc")), "-std=c99", "-Wall", "-Wextra", "-Werror",
             "-fPIC", "-shared", "-Wl,-soname,libgtk-4.so.1",
             str(ROOT / "tests/gui/fake_gtk4_runtime.c"),
             "-o", str(lib / "libgtk-4.so.1")])
        log_path = temp / "gtk.log"
        env = dict(os.environ, LD_LIBRARY_PATH=str(lib), BABET_FAKE_GTK_LOG=str(log_path))
        env.pop("BABET_FAKE_GTK_FAIL_SIGNAL", None)
        result = run([binary, str(ROOT / "tests/gui/widgets_contract.lua")], env)
        assert "GUI_WIDGETS_CONTRACT_OK" in result.stdout
        assert "SPIN_CHANGED_ERROR_SENTINEL" in result.stderr
        assert "CALENDAR_CHANGED_ERROR_SENTINEL" in result.stderr
        assert "yield" in result.stderr
        log = log_path.read_text()
        for marker in [
            "box-remove", "scrolled-child:set", "scrolled-child:clear",
            "spin-after-change", "calendar-after-change",
            "margin-top", "margin-end", "margin-bottom", "margin-start",
            "hexpand:true", "vexpand:true", "visible:false", "sensitive:false",
        ]:
            assert marker in log, marker
        print("[PASS] containers, ScrolledWindow, SpinButton, Calendar and common properties")

        # A signal connection failure must release the construction reference.
        cases = [
            ("value-changed", "spinButton", "destroy:spinButton"),
            ("day-selected", "calendar", "destroy:calendar"),
        ]
        for signal, constructor, destroyed in cases:
            script = temp / f"fail-{constructor}.lua"
            script.write_text(f'''\nassert(babet.gui.init())\nfor i = 1, 100 do\n    local widget, err = babet.gui.{constructor}()\n    assert(widget == nil and type(err) == "string" and err:find("cannot attach", 1, true), tostring(err))\nend\ncollectgarbage("collect")\nprint("GUI_SIGNAL_FAILURE_OK")\n''')
            failure_log = temp / f"failure-{signal}.log"
            failure_env = dict(env, BABET_FAKE_GTK_FAIL_SIGNAL=signal,
                               BABET_FAKE_GTK_LOG=str(failure_log))
            result = run([binary, str(script)], failure_env)
            assert "GUI_SIGNAL_FAILURE_OK" in result.stdout
            assert failure_log.read_text().splitlines().count(destroyed) == 100
            print(f"[PASS] {constructor} signal failure releases native resources")

    print("GUI widgets regression: 3 PASS / 0 FAIL")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"[FAIL] GUI widgets: {error}", file=sys.stderr)
        sys.exit(1)
