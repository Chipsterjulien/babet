#!/usr/bin/env python3
"""End-to-end regression: every completed-pipeline cleanup path is fast.

Each path is timed in a separate Babet process so a regression in close(),
__close or __gc cannot be hidden by a single loose aggregate threshold.
"""
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
MAX_SECONDS = 0.35


def run_mode(program: str, mode: str) -> float:
    before = time.monotonic()
    result = subprocess.run(
        [program, str(ROOT / "tests/process/pipeline_completed_cleanup.lua"), mode],
        capture_output=True, text=True, timeout=5,
        stdin=subprocess.DEVNULL,
    )
    duration = time.monotonic() - before
    marker = f"PIPELINE_COMPLETED_CLEANUP_OK\t{mode}"
    # Lua's print uses tabs between arguments.
    if result.returncode != 0 or marker not in result.stdout:
        raise AssertionError(
            f"pipeline cleanup mode {mode!r} failed:\n{result.stdout}\n{result.stderr}"
        )
    if duration >= MAX_SECONDS:
        raise AssertionError(
            f"completed pipeline {mode} took {duration:.3f}s (max {MAX_SECONDS:.2f}s)"
        )
    return duration


def main():
    if len(sys.argv) != 2:
        raise AssertionError("usage: test_pipeline_completed_cleanup.py /path/to/babet")
    program = str(Path(sys.argv[1]).resolve())
    timings = {mode: run_mode(program, mode) for mode in ("close", "scope", "gc")}
    summary = ", ".join(f"{mode}={value:.3f}s" for mode, value in timings.items())
    print(f"[PASS] completed pipeline cleanup paths: {summary}")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"[FAIL] completed pipeline cleanup: {error}", file=sys.stderr)
        sys.exit(1)
