#!/usr/bin/env python3
"""Initial hook policy and executable-image failures against the real CLI."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = r'''
local checks=0
local function check(ok) assert(ok); checks=checks+1 end
check(debug.gethook()==nil)
local early=coroutine.create(function()
    check(debug.gethook()==nil)
    assert(babet.signal.handle("USR1",function() end))
    check(debug.gethook()~=nil)
end)
check(debug.gethook(early)==nil)
assert(babet.signal.ignore("USR1")); assert(babet.signal.default("USR1"))
assert(babet.signal.handle("USR1",nil))
check(debug.gethook()==nil)
check(not pcall(babet.signal.handle,"USR1",42))
check(debug.gethook()==nil)
assert(babet.signal.handle("USR1",function() end))
local hook,mask,count=debug.gethook()
check(hook~=nil and mask=="" and count==10000)
check(debug.gethook(early)==nil)
assert(coroutine.resume(early))
local late=coroutine.create(function() check(debug.gethook()~=nil) end)
assert(coroutine.resume(late))
assert(babet.signal.default("USR1"))
check(debug.gethook()~=nil)
local job=assert(babet.workers.spawn([[return debug.gethook()==nil]]))
local ok,value=job:join(10); check(ok and value==true)
local db=assert(babet.sqlite.open(":memory:"))
local values=table.pack(db:query("SELECT 1"))
check(values.n==4 and values[1]==values[4] and values[2]==nil and values[3]==nil)
values[1]:close()
local entries={}; table.insert(entries,(db:query("SELECT 1")))
check(#entries==1); entries[1]:close(); db:close()
print("STARTUP_CHECKS="..checks)
'''


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: test_startup_state.py /path/to/babet")
    binary = Path(sys.argv[1]).resolve()
    total = 0
    with tempfile.TemporaryDirectory(prefix="babet-startup-") as temporary:
        root = Path(temporary)

        def run(args, env=None):
            return subprocess.run([str(x) for x in args], cwd=root, env=env,
                                  capture_output=True, text=True, timeout=30)

        project = root / "project"
        project.mkdir()
        script = project / "main.lua"
        script.write_text(SCRIPT)
        app = root / "application"
        built = run([binary, "-c", project, app])
        assert built.returncode == 0, built.stdout+built.stderr
        for mode, command in (("file", [binary, script]), ("folder", [binary, project]),
                              ("embedded", [app])):
            result = run(command)
            assert result.returncode == 0, result.stdout+result.stderr
            assert "STARTUP_CHECKS=14" in result.stdout, result.stdout
            total += 14
            print(f"[PASS] {mode}: 14 startup/hook/SQLite contracts", flush=True)

        preload = root / "image-io.so"
        subprocess.run([*shlex.split(os.environ.get("CC", "cc")), "-shared", "-fPIC",
                        str(ROOT / "tests/embedded/image_io_failure.c"), "-ldl",
                        "-o", str(preload)], check=True)
        disk = root / "disk.lua"
        disk.write_text('print("DISK_SCRIPT_EXECUTED")\n')
        clean = root / "clean"
        clean.mkdir()
        (clean / "main.lua").write_text('print("GENERATED_MAIN_EXECUTED")\n')
        simple_app = root / "simple-app"
        result = run([binary, "-c", clean, simple_app])
        assert result.returncode == 0, result.stdout+result.stderr
        # Positive controls distinguish a bare runtime from a valid application.
        assert run([binary, disk]).stdout.strip() == "DISK_SCRIPT_EXECUTED"
        assert run([simple_app, disk]).stdout.strip() == "GENERATED_MAIN_EXECUTED"
        total += 2
        for fault in ("open-2", "open-13", "open-24", "read", "eof", "seek"):
            preloads = [os.environ.get("BABET_TEST_ASAN_RUNTIME", ""), str(preload),
                        os.environ.get("LD_PRELOAD", "")]
            env = dict(os.environ, LD_PRELOAD=":".join(x for x in preloads if x),
                       BABET_TEST_IMAGE_FAULT=fault)
            for executable in (binary, simple_app):
                for operation in ("run", "build"):
                    output = root / "must-not-be-replaced"
                    output.write_bytes(b"PREVIOUS")
                    args = [disk] if operation == "run" else ["-c", clean, output]
                    result = run([executable, *args], env=env)
                    assert result.returncode == 1, (fault, executable, result)
                    assert f"IMAGE_IO_INJECTED:{fault}" in result.stderr, result.stderr
                    assert ("cannot open executable image" in result.stderr or
                            "cannot inspect executable image" in result.stderr), result.stderr
                    assert "EXECUTED" not in result.stdout, result.stdout
                    assert output.read_bytes() == b"PREVIOUS"
                    total += 1
            print(f"[PASS] image {fault}: bare/generated runtime refuses script and builder", flush=True)
    print(f"startup state runtime: {total} PASS / 0 FAIL")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"[FAIL] startup state: {error}", file=sys.stderr)
        raise SystemExit(1)
