#!/usr/bin/env python3
"""Focused regressions for the log checker and its explicit, additive repair."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HELPER = Path(__file__).resolve().with_name("test_log_ignore.py")


def main():
    passed = []

    def success(name):
        passed.append(name)
        print("[PASS] " + name)

    with tempfile.TemporaryDirectory(prefix="babet-log-contracts-") as directory:
        base = Path(directory)
        project = base / "project with space's"
        (project / "tools").mkdir(parents=True)
        script = project / "tools/test_log_ignore.py"
        shutil.copyfile(HELPER, script)
        ignore = project / ".gitignore"

        def run(expected, *args, env=None):
            result = subprocess.run([sys.executable, str(script), *args],
                                    env=env, cwd=base, capture_output=True, text=True)
            assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
            return result.stdout + result.stderr

        good = b"# project rules\n*.o\nlocal-only/\nbabet-tests*.txt\n"
        ignore.write_bytes(good)
        run(0)
        assert ignore.read_bytes() == good
        success("valid rules and project path with spaces/apostrophe")

        old = b"# custom rules\nlocal-only/\nbabet-tests.txt\n"
        ignore.write_bytes(old)
        message = run(1)
        assert "babet-tests-desktop-validation.txt" in message and "--repair" in message
        assert ignore.read_bytes() == old
        success("missing wildcard is diagnosed without editing the file")

        ignore.chmod(0o640)
        run(0, "--repair")
        fixed = ignore.read_bytes()
        assert fixed.startswith(old) and fixed.endswith(b"babet-tests*.txt\n")
        assert ignore.stat().st_mode & 0o777 == 0o640
        run(0, "--repair")
        assert ignore.read_bytes() == fixed
        success("repair preserves existing bytes and permissions and is idempotent")

        crlf = b"# custom rules\r\nlocal-only/\r\nbabet-tests.txt"
        ignore.write_bytes(crlf)
        run(0, "--repair")
        assert ignore.read_bytes() == crlf + b"\r\nbabet-tests*.txt\r\n"
        success("CRLF and missing final newline are preserved")

        negated = good + b"!babet-tests-desktop-validation.txt\n"
        ignore.write_bytes(negated)
        run(1)
        run(0, "--repair")
        assert ignore.read_bytes().startswith(negated)
        success("an overriding log exception is repaired additively")

        ignore.write_bytes(good + b"*.lua\n")
        assert "source witness" in run(1)
        success("an overbroad source exclusion remains a distinct failure")

        ignore.unlink()
        assert "project .gitignore is missing" in run(1, "--repair")
        assert not ignore.exists()
        success("missing project file is diagnosed without inventing replacement rules")

        ignore.write_bytes(good)
        config_home = base / "config"
        (config_home / "git").mkdir(parents=True)
        config = config_home / "git/config"
        template = base / "custom-template"
        (template / "info").mkdir(parents=True)
        (template / "info/exclude").write_text("*.lua\n")
        env = dict(os.environ, XDG_CONFIG_HOME=str(config_home))
        config.write_text("[init]\n\ttemplateDir = " + json.dumps(str(template)) + "\n")
        run(0, env=env)
        success("personal Git template exclusions do not contaminate the fixture")

        config.write_text("[core]\n\tbare = true\n")
        run(0, env=env)
        success("personal Git core.bare does not contaminate the fixture")

        fake_bin = base / "fake-bin"
        fake_bin.mkdir()
        fake_git = fake_bin / "git"
        fake_git.write_text("#!/bin/sh\necho 'forced Git failure for diagnostic test' >&2\nexit 128\n")
        fake_git.chmod(0o755)
        message = run(1, env=dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ.get("PATH", "")))
        assert "forced Git failure for diagnostic test" in message
        assert "does not ignore" not in message
        success("Git execution errors retain their original diagnostic")

    print(f"Log ignore regressions: {len(passed)} PASS / 0 FAIL")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"[FAIL] Log ignore regression: {error}", file=sys.stderr)
        sys.exit(1)
