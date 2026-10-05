#!/usr/bin/env python3
"""Bound os.exit/locale regressions in fresh folder and embedded processes."""
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: test_worker_process_state.py /path/to/babet")
    binary = Path(sys.argv[1]).resolve()
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="babet-worker-state-") as temp:
        work = Path(temp)
        project = work / "project"
        project.mkdir()
        (project / "main.lua").write_bytes((root / "tests/workers/process_state.lua").read_bytes())
        app = work / "application"

        def run(args, expected=0):
            result = subprocess.run([str(x) for x in args], cwd=work,
                                    capture_output=True, text=True, timeout=60)
            if result.returncode != expected:
                raise AssertionError(f"{args}: exit={result.returncode}, expected={expected}\n"
                                     f"{result.stdout}\n{result.stderr}")
            return result.stdout

        run([binary, "--create-exe", project, app])
        for mode, command in (("folder", [binary, project]), ("embedded", [app])):
            for scenario, count in (("exit", 15), ("locale", 9), ("failed-spawn", 1)):
                print(f"[INFO] Worker process state: {mode}/{scenario}", flush=True)
                output = run([*command, scenario])
                # An accidental os.exit(0) must not masquerade as success.
                if f"Process state: {count} PASS" not in output:
                    raise AssertionError(f"Missing completion marker\n{output}")
                print(output, end="", flush=True)
            for form, status in (("code", 23), ("close", 23), ("yes", 0),
                                 ("no", 1), ("default", 0)):
                run([*command, "main-exit", form], status)
                print(f"[PASS] {mode}: main os.exit {form} retains status {status}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"[FAIL] worker process state: {error}", file=sys.stderr)
        raise SystemExit(1)
