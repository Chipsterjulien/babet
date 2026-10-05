#!/usr/bin/env python3
"""Run deterministic SQLite cursor lifetime regressions in both CLI modes."""
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: test_lifecycle_runtime.py /path/to/babet")
    binary = Path(sys.argv[1]).resolve()
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="babet-lifecycle-") as temp:
        work = Path(temp)
        project = work / "project"
        project.mkdir()
        (project / "main.lua").write_bytes((root / "tests/lifecycle/sqlite_close.lua").read_bytes())
        app = work / "application"
        def run(args):
            result = subprocess.run([str(x) for x in args], cwd=work,
                                    capture_output=True, text=True, timeout=45)
            if result.returncode:
                raise AssertionError(f"exit={result.returncode}\n{result.stdout}\n{result.stderr}")
            return result.stdout
        print("[INFO] SQLite lifecycle in folder mode", flush=True)
        print(run([binary, project, work / "folder.db"]), end="", flush=True)
        run([binary, "--create-exe", project, app])
        print("[INFO] SQLite lifecycle in embedded mode", flush=True)
        print(run([app, work / "embedded.db"]), end="", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"[FAIL] lifecycle runtime: {error}", file=sys.stderr)
        raise SystemExit(1)
