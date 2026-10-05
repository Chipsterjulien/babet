#!/usr/bin/env python3
"""Filesystem regressions against the real runtime, with bounded subprocesses."""
from pathlib import Path
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: test_tree_safety.py /path/to/babet")
    binary = Path(sys.argv[1]).resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise SystemExit(f"babet executable not found: {binary}")
    project = Path(__file__).resolve().parent.parent
    passes = 0

    def passed(name):
        nonlocal passes
        passes += 1
        print(f"[PASS] {name}", flush=True)

    with tempfile.TemporaryDirectory(prefix="babet-tree-safety-") as temp:
        root = Path(temp)
        preload = root / "move_after_scan.so"
        subprocess.run([
            os.environ.get("CC", "cc"), "-shared", "-fPIC", "-O2",
            "-Wall", "-Wextra", "-Werror",
            str(project / "tests/filesystem/move_after_scan.c"), "-ldl",
            "-o", str(preload),
        ], check=True)

        def run_move(src, dst, env=None):
            script = root / "move.lua"
            quote = lambda p: json.dumps(str(p), ensure_ascii=False)
            script.write_text(
                f"local ok, err = babet.moveTree({quote(src)}, {quote(dst)})\n"
                "assert(ok == nil and type(err) == 'string' and #err > 0,\n"
                "    'moveTree must reject this operation: '..tostring(ok))\n"
                "print(err)\n", encoding="utf-8")
            result = subprocess.run([str(binary), str(script)], env=env,
                                    capture_output=True, text=True, timeout=10)
            if result.returncode:
                raise AssertionError(result.stdout + result.stderr)

        # The hook runs after a real file move, thus after the complete scan.
        # It has no timing assumptions and must leave a marker proving it ran.
        for mode in ("late_root", "late_nested", "replace_link", "exdev"):
            case = root / mode
            src, dst = case / "src", case / "dst"
            (src / "nested/deeper").mkdir(parents=True)
            dst.mkdir()
            trigger = src / ("pipe" if mode == "exdev" else "transfer")
            if mode == "exdev":
                os.mkfifo(trigger)
            else:
                trigger.write_text("ORIGINAL", encoding="utf-8")
            late = src / ("nested/late" if mode == "late_nested" else "late")
            if mode == "replace_link":
                late = src / "link"
                late.symlink_to("transfer")
            marker = case / "injected"
            preloads = [os.environ.get("BABET_TEST_ASAN_RUNTIME", ""),
                        str(preload), os.environ.get("LD_PRELOAD", "")]
            env = dict(os.environ, LD_PRELOAD=":".join(p for p in preloads if p),
                       BABET_TEST_TREE_MODE=mode,
                       BABET_TEST_TREE_TRIGGER=str(trigger),
                       BABET_TEST_TREE_LATE=str(late),
                       BABET_TEST_TREE_MARKER=str(marker))
            run_move(src, dst, env)
            assert marker.is_file(), "renameat injection did not run"
            if mode == "exdev":
                assert stat.S_ISFIFO(trigger.lstat().st_mode)
                assert not (dst / "pipe").exists()
                passed("FIFO fallback rejects EXDEV without blocking or removing FIFO")
            else:
                assert late.read_text(encoding="utf-8") == "LATE-DATA"
                assert (dst / "transfer").read_text(encoding="utf-8") == "ORIGINAL"
                if mode == "replace_link":
                    assert (dst / "link").is_symlink()
                    assert os.readlink(dst / "link") == "transfer"
                passed(f"moveTree preserves untransferred source data ({mode})")

        # Also exercise a genuine cross-device move when this host provides a
        # writable second filesystem. The injected EXDEV test above is mandatory.
        second = Path("/dev/shm")
        if (second.is_dir() and os.access(second, os.W_OK) and
                second.stat().st_dev != root.stat().st_dev):
            src = root / "real_fifo"
            src.mkdir()
            os.mkfifo(src / "pipe")
            dst = Path(tempfile.mkdtemp(prefix="babet-tree-safety-", dir=second))
            try:
                run_move(src, dst)
                assert stat.S_ISFIFO((src / "pipe").lstat().st_mode)
                assert not (dst / "pipe").exists()
                passed("FIFO on a real second filesystem returns an error promptly")
            finally:
                shutil.rmtree(dst)
        else:
            print("[SKIP] real second filesystem unavailable; injected EXDEV tested")
    print(f"tree safety runtime: {passes} PASS / 0 FAIL", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"[FAIL] tree safety runtime: {error}", file=sys.stderr)
        raise SystemExit(1)
