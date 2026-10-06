#!/usr/bin/env python3
"""Entry contracts using a fake GTK DSO; no GTK headers or display required."""
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(command, env=None):
    result = subprocess.run(command, env=env, text=True, capture_output=True,
                            stdin=subprocess.DEVNULL, timeout=45)
    if result.returncode:
        raise AssertionError(f"{command!r}: exit {result.returncode}\n"
                             f"{result.stdout[-3000:]}\n{result.stderr[-6000:]}")
    return result


def main():
    if len(sys.argv) != 2:
        raise AssertionError("usage: python3 tools/test_gui_entry.py /path/to/babet")
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="babet-gui-entry-") as directory:
        temp = Path(directory)
        lib = temp / "lib"
        lib.mkdir()
        run([*shlex.split(os.environ.get("CC", "cc")), "-std=c99", "-Wall", "-Wextra", "-Werror",
             "-fPIC", "-shared", "-Wl,-soname,libgtk-4.so.1",
             str(ROOT / "tests/gui/fake_gtk4_runtime.c"),
             "-o", str(lib / "libgtk-4.so.1")])
        env = dict(os.environ, LD_LIBRARY_PATH=str(lib),
                   BABET_FAKE_GTK_LOG=str(temp / "gtk.log"))
        env.pop("BABET_FAKE_GTK_FAIL_SIGNAL", None)
        result = run([binary, str(ROOT / "tests/gui/entry_contract.lua")], env)
        assert "ENTRY_CONTRACT_OK" in result.stdout
        assert "ENTRY_CHANGED_ERROR_SENTINEL" in result.stderr
        assert "yield" in result.stderr
        log = (temp / "gtk.log").read_text()
        for marker in ["placeholder:Saisir…", "placeholder:Nouveau repère",
                       "editable:false", "editable:true"]:
            assert marker in log, marker
        print("[PASS] Entry values, validation, callbacks, reentry, coroutines and GC cycles")

        project = temp / "project"
        project.mkdir()
        shutil.copyfile(ROOT / "tests/gui/entry_events.lua", project / "main.lua")
        for mode, path in [("file", project / "main.lua"), ("folder", project)]:
            result = run([binary, str(path)], env)
            assert "ENTRY_EVENTS_OK" in result.stdout
            assert "ENTRY_ACTIVATE_ERROR_SENTINEL" in result.stderr
            assert "REPLACED_HANDLER_RAN" not in result.stderr
            assert "DISCONNECTED_HANDLER_RAN" not in result.stderr
            print(f"[PASS] Entry {mode}: activation, parent ownership and callback errors")
        app = temp / "entry-app"
        run([binary, "--create-exe", str(project), str(app)])
        shutil.rmtree(project)
        result = run([str(app)], env)
        assert "ENTRY_EVENTS_OK" in result.stdout
        assert "ENTRY_ACTIVATE_ERROR_SENTINEL" in result.stderr
        assert "REPLACED_HANDLER_RAN" not in result.stderr
        assert "DISCONNECTED_HANDLER_RAN" not in result.stderr
        print("[PASS] Entry generated application runs after source removal")

        # An injected connection failure must immediately release GTK ownership.
        failure = temp / "failure.lua"
        failure.write_text('''
assert(babet.gui.init())
for i = 1, 100 do
    local entry, err = babet.gui.entry()
    assert(entry == nil and type(err) == "string" and
           err:find("cannot attach", 1, true), tostring(err))
end
collectgarbage("collect")
print("ENTRY_FAILURE_OK")
''')
        for signal in ["destroy", "changed", "activate"]:
            log_path = temp / f"failure-{signal}.log"
            result = run([binary, str(failure)], dict(
                env, BABET_FAKE_GTK_FAIL_SIGNAL=signal,
                BABET_FAKE_GTK_LOG=str(log_path)))
            assert "ENTRY_FAILURE_OK" in result.stdout
            assert log_path.read_text().splitlines().count("destroy:entry") == 100
            print(f"[PASS] Entry {signal} connection failure releases native resources")
    print("GUI Entry regression: 7 PASS / 0 FAIL")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"[FAIL] GUI Entry: {error}", file=sys.stderr)
        sys.exit(1)
