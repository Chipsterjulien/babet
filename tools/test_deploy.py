#!/usr/bin/env python3
"""Exercise real deploy/install commands in private, unprivileged fixtures."""
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


def main():
    print("[INFO] deployment preflight lot17c", flush=True)
    binary = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else None
    rules = (ROOT / ".gitignore").read_text().splitlines()
    assert "__pycache__/" in rules and "*.py[cod]" in rules, (
        "missing Python cache rules: extract the patch including hidden .gitignore")
    print("[PASS] project includes Python cache ignore rules", flush=True)
    passed = 1
    # These fixtures contain executables; do not put them on a noexec TMPDIR.
    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    real_tools = {name: shutil.which(name) for name in
                  ("bash", "dirname", "mktemp", "rm", "mkdir", "install", "mv", "sleep")}
    assert all(real_tools.values()), real_tools
    with tempfile.TemporaryDirectory(prefix="deploy-tests-", dir=build) as temporary:
        root = Path(temporary)
        cases = [("root-upx", "0", True, "ok"),
                 ("sudo space's-upx", "1000", True, "ok"),
                 ("without-upx", "0", False, "ok"),
                 ("build-failure", "0", True, "build"),
                 ("missing-binary", "0", True, "missing"),
                 ("packaging-failure", "1000", True, "package"),
                 ("application-failure", "0", True, "application"),
                 ("wrong-result", "0", True, "output"),
                 ("noexec-tmpdir", "1000", True, "noexec"),
                 ("temporary-failure", "0", True, "temporary"),
                 ("partial-copy", "0", True, "copy"),
                 ("interrupted-copy", "1000", True, "interrupt"),
                 ("rename-failure", "1000", True, "rename"),
                 ("running-inode", "0", True, "running"),
                 ("replace-symlink", "1000", True, "symlink"),
                 ("refuse-directory", "0", True, "directory")]
        if binary:
            cases += [("real-root", "0", True, "real"),
                      ("real-sudo", "1000", True, "real")]
        for name, uid, upx, mode in cases:
            case = root / name
            tools = case / "commands"
            tools.mkdir(parents=True)
            (case / "test").mkdir()
            temporary_files = case / "temporary"
            temporary_files.mkdir()
            install_dir = case / "installed-bin"
            install_dir.mkdir()
            # Keep the copied utility's filename as well as argv[0]: some
            # multicall launchers derive their command from the executed path.
            installed = install_dir / ("sleep" if mode == "running" else "babet")
            log = case / "flow.log"
            for tool in ("dirname", "rm", "mkdir"):
                (tools / tool).symlink_to(real_tools[tool])
            shutil.copy2(ROOT / "build_and_deploy.sh", case / "build_and_deploy.sh")
            executable(case / "build_local.sh", '''#!/bin/bash
printf 'build\n' >> "$DEPLOY_LOG"
[ "$DEPLOY_MODE" != build ]
''')
            runtime = case / "test/babet"
            if mode == "real":
                shutil.copy2(binary, runtime)
            elif mode != "missing":
                executable(runtime, f"#!{sys.executable}\n" + r'''
import os, pathlib, sys
with open(os.environ["DEPLOY_LOG"], "a") as log: log.write("package\n")
assert len(sys.argv) == 4 and sys.argv[1] == "-c", sys.argv
if os.environ["DEPLOY_MODE"] == "package": sys.exit(72)
output = pathlib.Path(sys.argv[3])
output.write_text("#!" + sys.executable + "\n" + """
import os, sys
with open(os.environ["DEPLOY_LOG"], "a") as log: log.write("application\\n")
if os.environ["DEPLOY_MODE"] == "application": sys.exit(73)
print("WRONG" if os.environ["DEPLOY_MODE"] == "output" else "BABET_DEPLOY_SMOKE_OK")
""")
# Model execve EACCES on the advertised temporary filesystem, without mounting.
denied = os.environ["DEPLOY_MODE"] == "noexec" and output.is_relative_to(os.environ["TMPDIR"])
output.chmod(0o644 if denied else 0o755)
''')
            executable(tools / "id", '#!/bin/bash\nprintf "%s\\n" "$DEPLOY_UID"\n')
            executable(tools / "sudo", '#!/bin/bash\nprintf "sudo\\n" >> "$DEPLOY_LOG"\nexec "$@"\n')
            # Redirect only the install shell's target argument. Its unchanged
            # here-document runs real mktemp/install/mv in the private folder.
            executable(tools / "bash", f"#!{sys.executable}\n" + r'''
import os, pathlib, sys
args = sys.argv[1:]
if args[:2] == ["-s", "--"]:
    assert len(args) == 4 and args[3] == "/usr/local/bin/babet", args
    assert pathlib.Path(args[2]) == pathlib.Path(os.environ["DEPLOY_CASE"]) / "test/babet"
    args[3] = os.environ["DEPLOY_TARGET"]
os.execv(os.environ["DEPLOY_REAL_BASH"], [os.environ["DEPLOY_REAL_BASH"], *args])
''')
            executable(tools / "mktemp", f"#!{sys.executable}\n" + r'''
import os, pathlib, subprocess, sys
args = sys.argv[1:]
pattern = pathlib.Path(args[-1])
case = pathlib.Path(os.environ["DEPLOY_CASE"])
if args[:1] == ["-d"]:
    assert pattern.parent in (case / "build", case / "temporary"), args
    label = "smoke:"
else:
    target = pathlib.Path(os.environ["DEPLOY_TARGET"])
    assert len(args) == 1 and pattern.parent == target.parent, args
    assert pattern.name == target.name + ".tmp.XXXXXX", args
    if os.environ["DEPLOY_MODE"] == "temporary": sys.exit(74)
    label = "temporary:"
result = subprocess.run([os.environ["DEPLOY_REAL_MKTEMP"], *args], capture_output=True, text=True)
if result.returncode == 0:
    with open(os.environ["DEPLOY_LOG"], "a") as log: log.write(label + result.stdout)
sys.stdout.write(result.stdout); sys.stderr.write(result.stderr); sys.exit(result.returncode)
''')
            executable(tools / "install", f"#!{sys.executable}\n" + r'''
import os, pathlib, signal, subprocess, sys
args = sys.argv[1:]
assert args[:3] == ["-m", "0755", "--"] and len(args) == 5, args
destination = pathlib.Path(args[-1])
target = pathlib.Path(os.environ["DEPLOY_TARGET"])
assert destination.parent == target.parent and destination.name.startswith(target.name + ".tmp."), args
with open(os.environ["DEPLOY_LOG"], "a") as log: log.write("copy:start\n")
if os.environ["DEPLOY_MODE"] in ("copy", "interrupt"):
    destination.write_bytes(b"PARTIAL_RUNTIME")
    if os.environ["DEPLOY_MODE"] == "interrupt": os.kill(os.getppid(), signal.SIGTERM)
    sys.exit(75)
result = subprocess.run([os.environ["DEPLOY_REAL_INSTALL"], *args])
if result.returncode == 0:
    with open(os.environ["DEPLOY_LOG"], "a") as log: log.write("copy:complete\n")
sys.exit(result.returncode)
''')
            executable(tools / "mv", f"#!{sys.executable}\n" + r'''
import os, pathlib, subprocess, sys
args = sys.argv[1:]
assert args[:2] == ["-fT", "--"] and len(args) == 4, args
source, target = map(pathlib.Path, args[-2:])
assert target == pathlib.Path(os.environ["DEPLOY_TARGET"]) and source.parent == target.parent, args
assert source.name.startswith(target.name + ".tmp."), args
with open(os.environ["DEPLOY_LOG"], "a") as log: log.write("rename\n")
if os.environ["DEPLOY_MODE"] == "rename": sys.exit(76)
sys.exit(subprocess.run([os.environ["DEPLOY_REAL_MV"], *args]).returncode)
''')
            if upx:
                executable(tools / "upx", '#!/bin/bash\nprintf "upx\\n" >> "$DEPLOY_LOG"\nexit 89\n')
            installed.write_bytes(b"PREVIOUS_RUNTIME")
            outside = case / "symlink-target"
            if mode == "symlink":
                outside.write_bytes(b"UNRELATED_CONTENT")
                installed.unlink()
                installed.symlink_to(outside)
            if mode == "directory":
                installed.unlink(); installed.mkdir()
                (installed / "keep").write_bytes(b"DIRECTORY_CONTENT")
            if mode == "running":
                shutil.copy2(real_tools["sleep"], installed)
            before = installed.lstat()
            before_bytes = installed.read_bytes() if mode != "directory" else None
            old_fd = os.open(installed, os.O_RDONLY) if mode != "directory" else None
            child = subprocess.Popen([str(installed), "30"]) if mode == "running" else None
            env = dict(os.environ, PATH=str(tools), TMPDIR=str(temporary_files),
                       DEPLOY_UID=uid, DEPLOY_MODE=mode, DEPLOY_TARGET=str(installed),
                       DEPLOY_LOG=str(log), DEPLOY_CASE=str(case),
                       **{"DEPLOY_REAL_" + k.upper(): v for k, v in real_tools.items()})
            try:
                result = subprocess.run([real_tools["bash"], str(case / "build_and_deploy.sh")],
                                        env=env, capture_output=True, text=True, timeout=30)
                flow = log.read_text().splitlines()
                assert "upx" not in flow, (name, flow)
                success = mode in ("ok", "real", "noexec", "running", "symlink")
                if success:
                    assert result.returncode == 0, (name, result)
                    assert not installed.is_symlink() and installed.read_bytes() == runtime.read_bytes(), name
                    assert installed.stat().st_ino != before.st_ino, name
                    assert stat.S_IMODE(installed.stat().st_mode) == 0o755, name
                    assert flow.index("copy:complete") < flow.index("rename"), flow
                    if mode != "real":
                        assert flow.index("build") < flow.index("package") < flow.index("application") < flow.index("copy:start"), flow
                    assert flow.count("sudo") == (1 if uid != "0" else 0), flow
                else:
                    assert result.returncode != 0, (name, result)
                    assert installed.lstat().st_ino == before.st_ino, name
                    if mode == "directory":
                        assert list(installed.iterdir()) == [installed / "keep"]
                        assert (installed / "keep").read_bytes() == b"DIRECTORY_CONTENT"
                    else:
                        assert installed.read_bytes() == before_bytes, name
                    if mode in ("build", "missing", "package", "application", "output"):
                        assert "copy:start" not in flow and "sudo" not in flow, flow
                    if mode in ("temporary", "copy", "interrupt"):
                        assert "rename" not in flow, flow
                    if mode == "interrupt": assert result.returncode == 143, result
                if old_fd is not None:
                    assert os.read(old_fd, len(before_bytes) + 1) == before_bytes, name
                if child:
                    assert child.poll() is None, "running executable was disrupted"
                    # Keep the old inode pinned and readable across publication.
                    # Child /proc entries need not be visible in embedded CI.
                    assert os.fstat(old_fd).st_ino == before.st_ino, name
                if mode == "symlink": assert outside.read_bytes() == b"UNRELATED_CONTENT"
                for line in flow:
                    if line.startswith("smoke:"):
                        assert Path(line[6:]).parent == case / "build", line
                assert not list(temporary_files.iterdir()), (name, "TMPDIR used/leaked")
                assert not list((case / "build").glob("deploy-smoke.*")), name
                assert list(install_dir.iterdir()) == [installed], (name, "install temporary leaked")
            finally:
                if old_fd is not None: os.close(old_fd)
                if child:
                    child.terminate(); child.wait(timeout=5)
            passed += 1
            print(f"[PASS] deployment {name}: atomic publication, preservation and cleanup", flush=True)
    print(f"deployment flow: {passed} PASS / 0 FAIL")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"[FAIL] deployment: {error}", file=sys.stderr)
        raise SystemExit(1)
