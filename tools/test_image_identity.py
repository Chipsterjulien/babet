#!/usr/bin/env python3
"""Exercise image identity with incidental ZIP bytes and damaged applications."""
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

from embedded_image_fixtures import MAGIC, marker_offset, update_checksum


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: test_image_identity.py /path/to/babet")
    binary = Path(sys.argv[1]).resolve()
    passed = 0
    skipped = 0
    with tempfile.TemporaryDirectory(prefix="babet-image-identity-") as temporary:
        root = Path(temporary)

        def run(args):
            return subprocess.run([str(x) for x in args], cwd=root,
                                  capture_output=True, text=True, timeout=30)

        def check(label):
            nonlocal passed
            passed += 1
            print(f"[PASS] {label}", flush=True)

        def executable(name, content):
            path = root / name
            path.write_bytes(content)
            path.chmod(0o755)
            return path

        project = root / "project"
        project.mkdir()
        (project / "main.lua").write_text('print("GENERATED_APP_EXECUTED")\n')
        disk = root / "disk.lua"
        disk.write_text('print("DISK_SCRIPT_EXECUTED")\n')
        folder = root / "disk-project"
        folder.mkdir()
        (folder / "main.lua").write_text('print("DISK_FOLDER_EXECUTED")\n')
        app = root / "application"
        result = run([binary, "-c", project, app])
        assert result.returncode == 0, result.stdout + result.stderr
        bare = binary.read_bytes()
        image = app.read_bytes()
        marker = marker_offset(image)
        version, generated, start, size = struct.unpack_from("<IIQQ", image, marker + 32)
        assert (version, generated, start, start + size) == (1, 1, len(bare), len(image))
        assert marker_offset(bare) == marker
        result = run([app, disk])
        assert result.returncode == 0 and result.stdout.strip() == "GENERATED_APP_EXECUTED", result
        check("generated descriptor bounds and application arguments")

        # The real loaded identity must win even over a valid or malformed
        # EOCD at the exact end of an otherwise bare runtime.
        for name, suffix in (("near-tail", b"PK\x05\x06" + b"X" * 96),
                             ("exact-tail", b"PK\x05\x06" + b"X" * 18),
                             ("empty-zip", b"PK\x05\x06" + b"\0" * 18),
                             ("unmarked-zip", image[start:])):
            altered = executable("bare-variant", bare + suffix)
            result = run([altered, "--version"])
            assert result.returncode == 0 and result.stdout.startswith("babet "), result
            result = run([altered, "-c", project, root / "rebuilt"])
            assert result.returncode == 0, result.stdout + result.stderr
            result = run([root / "rebuilt"])
            assert result.returncode == 0 and "GENERATED_APP_EXECUTED" in result.stdout, result
            check(f"bare runtime with {name}: version, builder and generated execution")

        def rejects(content, label):
            variant = executable("damaged-app", content)
            for args in ([disk], [folder], ["-c", project, root / "preserved"]):
                output = root / "preserved"
                output.write_bytes(b"PREVIOUS_OUTPUT")
                result = run([variant, *args])
                assert result.returncode == 1, (label, args, result)
                assert result.stderr.strip(), (label, result)
                assert "EXECUTED" not in result.stdout, (label, result)
                assert output.read_bytes() == b"PREVIOUS_OUTPUT"
            check(f"{label}: refuses file, folder and builder modes")

        for cut in (10, 60, size):
            rejects(image[:-cut], f"truncated by {cut} bytes")
        rejects(image + b"UNEXPECTED_TRAILING_DATA", "appended data")
        rejects(image + image[start:], "appended second ZIP")
        damaged = bytearray(image)
        damaged[-22:-18] = b"BAD!"
        rejects(damaged, "damaged EOCD")
        damaged = bytearray(image)
        central = damaged.rfind(b"PK\x01\x02")
        assert central >= start
        damaged[central:central + 4] = b"BAD!"
        rejects(damaged, "damaged central directory")
        damaged = bytearray(image)
        name_size, extra_size = struct.unpack_from("<HH", damaged, start + 26)
        damaged[start + 30 + name_size + extra_size] ^= 0xff
        rejects(damaged, "damaged main.lua payload")
        rejects(image[:start] + image[start:].replace(b"main.lua", b"lost.lua"),
                "missing main.lua with otherwise valid ZIP")
        for label, field, value, repaired in (
                ("invalid descriptor checksum", 56, 0, False),
                ("invalid descriptor version", 32, 2 | (1 << 32), True),
                ("invalid descriptor flags", 32, 1 | (2 << 32), True),
                ("bare flag with application bounds", 32, 1, True),
                ("overflowing archive size", 48, (1 << 64) - 1, True),
                ("out-of-range archive offset", 40, (1 << 63) - 1, True)):
            damaged = bytearray(image)
            struct.pack_into("<Q", damaged, marker + field, value)
            if repaired:
                update_checksum(damaged, marker)
            rejects(damaged, label)

        # Duplicate candidates are refused before publication, including one
        # spanning the scanner's 64 KiB chunk boundary.
        padding = (65536 - 16 - len(bare)) % 65536
        duplicate = executable("ambiguous-builder", bare + b"X" * padding + MAGIC + b"\0" * 32)
        output = root / "preserved"
        output.write_bytes(b"PREVIOUS_OUTPUT")
        result = run([duplicate, "-c", project, output])
        assert result.returncode == 1 and "ambiguous executable image descriptor" in result.stderr, result
        assert output.read_bytes() == b"PREVIOUS_OUTPUT"
        assert not list(root.glob(".babet-output-*"))
        check("duplicate descriptor across chunk boundary preserves prior output")

        stripped = root / "stripped-runtime"
        shutil.copy2(binary, stripped)
        subprocess.run([os.environ.get("STRIP", "strip"), str(stripped)], check=True)
        assert marker_offset(stripped.read_bytes()) >= 0
        result = run([stripped, "-c", project, root / "stripped-app"])
        assert result.returncode == 0, result.stdout + result.stderr
        result = run([root / "stripped-app"])
        assert result.returncode == 0 and "GENERATED_APP_EXECUTED" in result.stdout, result
        check("stripped bare runtime retains descriptor and builds a working application")

        # Compression is deliberately unsupported for builders. Exercise the
        # real diagnostic when UPX is available, only on the normal runtime:
        # sanitizer runtimes are not a supported UPX input for this check.
        upx = shutil.which("upx")
        if os.environ.get("BABET_TEST_ASAN_RUNTIME"):
            print("[SKIP] UPX builder diagnostic: reserved for the normal build", flush=True)
            skipped += 1
        elif not upx:
            print("[SKIP] UPX builder diagnostic: upx is not installed", flush=True)
            skipped += 1
        else:
            packed = root / "upx-runtime"
            compressed = subprocess.run([upx, "--fast", "--no-progress", "-o", str(packed), str(stripped)],
                                        capture_output=True, text=True, timeout=180)
            if compressed.returncode:
                print("[SKIP] UPX cannot pack this runtime: " +
                      (compressed.stdout + compressed.stderr).strip()[-400:], flush=True)
                skipped += 1
            else:
                result = run([packed, "--version"])
                assert result.returncode == 0 and result.stdout.startswith("babet "), result
                output = root / "preserved"
                output.write_bytes(b"PREVIOUS_OUTPUT")
                result = run([packed, "-c", project, output])
                assert result.returncode == 1 and "compressed or rewritten (UPX?)" in result.stderr, result
                assert output.read_bytes() == b"PREVIOUS_OUTPUT"
                assert not list(root.glob(".babet-output-*"))
                check("UPX runtime: explicit builder refusal preserves prior output")

    print(f"image identity runtime: {passed} PASS / 0 FAIL / {skipped} SKIP")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"[FAIL] image identity: {error}", file=sys.stderr)
        raise SystemExit(1)
