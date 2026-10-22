#!/usr/bin/env python3
"""Check project log exclusions; --repair appends the rule without replacing rules."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
LOGS = (
    "babet-tests.txt",
    "babet-tests-desktop-correctifs.txt",
    "babet-tests-desktop-validation.txt",
    "babet-tests(20261021-184519).txt",
    "babet-tests-upx.txt",
)
SOURCE_WITNESS = "test-results-source.lua"


def inspect_rules(rules):
    # This fixture tests the project's rules, not personal Git configuration,
    # template info/exclude files or the surrounding working repository.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
    with tempfile.TemporaryDirectory(prefix="babet-log-ignore-") as directory:
        initialized = subprocess.run(
            ["git", "init", "--quiet", "--template=", directory],
            env=env, capture_output=True,
        )
        if initialized.returncode:
            raise RuntimeError("git init failed: " + initialized.stderr.decode("utf-8", "replace").strip())
        Path(directory, ".gitignore").write_bytes(rules)
        result = subprocess.run(
            ["git", "-C", directory, "-c", "core.excludesFile=" + os.devnull,
             "check-ignore", "--no-index", "-z", "--stdin"],
            input=b"\0".join(name.encode() for name in (*LOGS, SOURCE_WITNESS)) + b"\0",
            env=env, capture_output=True,
        )
        if result.returncode not in (0, 1):
            raise RuntimeError("git check-ignore failed: " + result.stderr.decode("utf-8", "replace").strip())
        ignored = set(result.stdout.split(b"\0")) - {b""}
        missing = [name for name in LOGS if name.encode() not in ignored]
        source_hidden = SOURCE_WITNESS.encode() in ignored
        return missing, source_hidden


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repair", action="store_true",
                        help="append babet-tests*.txt if needed, preserving existing rules")
    args = parser.parse_args()
    path = ROOT / ".gitignore"
    if not path.is_file():
        raise RuntimeError("project .gitignore is missing; restore that file before running this check")
    rules = path.read_bytes()
    missing, source_hidden = inspect_rules(rules)
    if args.repair and missing:
        newline = b"\r\n" if b"\r\n" in rules else b"\n"
        addition = (b"" if not rules or rules.endswith(b"\n") else newline)
        addition += b"babet-tests*.txt" + newline
        # Append only: preserve custom exclusions, comments, encoding and mode.
        with path.open("ab") as output:
            output.write(addition)
        print("[PASS] Added babet-tests*.txt; existing .gitignore rules preserved")
        missing, source_hidden = inspect_rules(path.read_bytes())
    elif args.repair:
        print("[PASS] Test log exclusions already work; .gitignore unchanged")
    if missing:
        print("[FAIL] .gitignore does not ignore: " + ", ".join(missing), file=sys.stderr)
        print("Repair from the project root: python3 tools/test_log_ignore.py --repair", file=sys.stderr)
    if source_hidden:
        print("[FAIL] .gitignore also hides the source witness " + SOURCE_WITNESS
              + "; inspect broad rules such as *.lua or *", file=sys.stderr)
    if missing or source_hidden:
        return 1
    print("[PASS] Project log exclusions work independently of personal Git configuration")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError) as error:
        print(f"[FAIL] Test log exclusion check: {error}", file=sys.stderr)
        sys.exit(1)
