#!/usr/bin/env python3
"""Offline regressions for partial dependency caches and the real build blocks.

Lua uses a tiny Makefile and CMake dependencies use a build stub. Archive
extraction, checksums, cache decisions, Lua make/clean and publication are real.
No download, compiler or project build directory is needed.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
BUILD = (ROOT / "build_local.sh").read_text()
HELPERS = ROOT / "tools/build_dependency_utils.sh"
VARIABLES = BUILD.split("# Variables\n", 1)[1].split("# Créer les répertoires nécessaires", 1)[0]
VERIFY = "verify_sha256() {" + BUILD.split("verify_sha256() {", 1)[1].split("\n}\n", 1)[0] + "\n}\n"
PASS = 0


def passed(message):
    global PASS
    PASS += 1
    print("[PASS] " + message, flush=True)


def run(script, args=(), env=None):
    return subprocess.run(["bash", "-eu", "-c", script, "bootstrap-test", *map(str, args)],
                          env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, timeout=30)


def ok(result):
    assert result.returncode == 0, result.stdout


def archive(path, name, files):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.suffix == ".zip":
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as output:
            for rel, data in files.items():
                output.writestr(name + "/" + rel, data)
    else:
        with tarfile.open(path, "w:xz" if path.suffix == ".xz" else "w:gz") as output:
            for rel, data in files.items():
                entry = tarfile.TarInfo(name + "/" + rel)
                entry.size = len(data)
                output.addfile(entry, io.BytesIO(data))
    return hashlib.sha256(path.read_bytes()).hexdigest()


def version(prefix):
    return re.search(r'^' + prefix + r'_VERSION="([^"]+)"', BUILD, re.M)[1]


def no_temporary(parent):
    assert not list(parent.glob(".extract-*")), "temporary extraction directory remains"


def helper_tests(tmp):
    for suffix in (".tar.gz", ".tar.xz", ".zip"):
        parent = tmp / ("helper " + suffix)
        dest = parent / "package"
        dest.mkdir(parents=True)
        (dest / "OLD").write_text("old source")
        path = parent / ("source" + suffix)
        archive(path, "package", {"Makefile": b"build input", "nested/file.c": b"source"})
        command = '. "$1"; babet_refresh_dependency_source "$2" "$3" package Makefile nested/file.c'
        ok(run(command, (HELPERS, dest, path)))
        assert (dest / "nested/file.c").read_bytes() == b"source" and not (dest / "OLD").exists()
        no_temporary(parent)
        passed("fresh dependency extraction replaces stale sources: " + suffix)
        (dest / "KEEP").write_text("preserve on failure")
        archive(path, "package", {"Makefile": b"incomplete archive"})
        assert run(command, (HELPERS, dest, path)).returncode != 0
        assert (dest / "KEEP").exists() and (dest / "nested/file.c").read_bytes() == b"source"
        no_temporary(parent)
        passed("incomplete dependency archive preserves the old tree: " + suffix)
        path.write_bytes(b"corrupt archive")
        assert run(command, (HELPERS, dest, path)).returncode != 0
        assert (dest / "KEEP").exists()
        no_temporary(parent)
        passed("failed dependency extraction is refused and cleaned: " + suffix)


def build_case(tmp, prefix, folder, name, suffix, start, end, inputs, outputs):
    case = tmp / (prefix + " builder's path with spaces")
    src = case / "build" / folder / name
    src.mkdir(parents=True)
    # Keep an apparent build entry point but omit the rest of the source.
    # For Lua this reproduces sed succeeding before root `make clean` fails.
    (src / "STALE").write_text("partial cache")
    (src / "src").mkdir()
    (src / "src/Makefile").write_text("MYCFLAGS=\nMYLIBS=\nALL_T=\n")
    (src / "CMakeLists.txt").write_text("incomplete old source")
    files = {rel: ("archive " + rel).encode() for rel in inputs}
    files["ARCHIVE_PAYLOAD"] = b"fresh source"
    if prefix == "LUA":
        files["Makefile"] = b".PHONY: linux clean\nlinux:\n\t$(MAKE) -C src all\nclean:\n\t$(MAKE) -C src clean\n"
        files["src/Makefile"] = b"""MYCFLAGS=
MYLIBS=
ALL_T=lua
.PHONY: all clean
all:
	test "$(MYCFLAGS)" = -fPIC
	test "$(MYLIBS)" = -lm
	test "$(ALL_T)" = liblua.a
	printf 'fresh Lua archive\\n' > liblua.a
clean:
	rm -f liblua.a
"""
    download = case / "downloads" / (name + suffix)
    digest = archive(download, name, files)
    block = BUILD.split(start, 1)[1].split(end, 1)[0]
    script = ('. "$1"\nSCRIPT_DIR="$2"\nSANITIZER_MODE=OFF\n' + VARIABLES +
              '\n' + prefix + '_SHA256="$3"\n' + VERIFY +
              '\ndownload_with_fallback() { echo "unexpected download" >&2; return 1; }\n' + block)
    stub = case / "fake bin"
    stub.mkdir()
    cmake = stub / "cmake"
    cmake.write_text("#!" + sys.executable + "\n" + '''import json, os, pathlib, sys
source = pathlib.Path(os.environ["BABET_CACHE_SOURCE"])
assert (source / "ARCHIVE_PAYLOAD").read_bytes() == b"fresh source"
assert not (source / "STALE").exists()
for rel in json.loads(os.environ["BABET_CACHE_OUTPUTS"]):
    p = pathlib.Path(os.environ["BABET_CACHE_CASE"]) / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("fresh CMake product")
''')
    cmake.chmod(0o755)
    env = dict(os.environ, PATH=str(stub) + os.pathsep + os.environ["PATH"],
               BABET_CACHE_SOURCE=str(src), BABET_CACHE_CASE=str(case),
               BABET_CACHE_OUTPUTS=json.dumps(outputs))

    def invoke(expected=digest):
        return run(script, (HELPERS, case, expected), env)

    ok(invoke())
    assert not (src / "STALE").exists()
    assert (src / "ARCHIVE_PAYLOAD").read_bytes() == b"fresh source"
    for rel in outputs:
        assert (case / rel).is_file(), rel
    no_temporary(src.parent)
    passed(prefix + " actual build block repairs a partial source cache")
    (src / "KEEP").write_text("complete cache")
    before = {rel: (case / rel).stat().st_mtime_ns for rel in outputs}
    ok(invoke())
    assert (src / "KEEP").exists()
    assert before == {rel: (case / rel).stat().st_mtime_ns for rel in outputs}
    passed(prefix + " actual build block reuses complete products")

    if prefix == "LUA":
        for header in ("lua.h", "lauxlib.h", "lualib.h", "luaconf.h"):
            (src / "src" / header).unlink()
            ok(invoke())
            assert (src / "src" / header).is_file(), header
        passed("Lua rebuilds when any of its four public headers is missing")
        (src / "src/liblua.a").unlink()
        (src / "KEEP").write_text("checksum sentinel")
        assert invoke("0" * 64).returncode != 0
        assert (src / "KEEP").exists() and not (src / "src/liblua.a").exists()
        passed("Lua checks SHA256 before replacing a partial source cache")
        bad = dict(files)
        bad["src/Makefile"] = b".PHONY: all clean\nall clean:\n\t@true\n"
        bad_digest = archive(download, name, bad)
        result = invoke(bad_digest)
        assert result.returncode != 0, result.stdout
        assert "manquants après compilation" in result.stdout, result.stdout
        passed("Lua build success without the required products is rejected")


def main():
    with tempfile.TemporaryDirectory(prefix="babet-dependency-cache-") as directory:
        tmp = Path(directory)
        helper_tests(tmp)
        lua = "lua-" + version("LUA")
        build_case(tmp, "LUA", "lua_build", lua, ".tar.gz",
                   "# Télécharger Lua si nécessaire\n", "# OpenSSL : TOUJOURS",
                   ["Makefile", "src/Makefile", "src/lapi.c", "src/lua.h", "src/lauxlib.h", "src/lualib.h", "src/luaconf.h"],
                   ["build/lua_build/" + lua + "/src/liblua.a"])
        zlib = "zlib-" + version("ZLIB")
        build_case(tmp, "ZLIB", "zlib", zlib, ".tar.gz",
                   "# Installer et compiler zlib si nécessaire.\n", "# Installer et compiler XZ Utils",
                   ["CMakeLists.txt", "zlib.h"],
                   ["build/zlib/install/" + p for p in ("lib/libz.a", "include/zlib.h", "include/zconf.h")])
        xz = "xz-" + version("XZ")
        build_case(tmp, "XZ", "xz", xz, ".tar.xz",
                   "# Installer et compiler XZ Utils / liblzma si nécessaire.\n", "# Installer et compiler bzip2",
                   ["CMakeLists.txt", "src/liblzma/api/lzma.h"],
                   ["build/xz/install/" + p for p in ("lib/liblzma.a", "include/lzma.h", "include/lzma/version.h")])
        absl = "abseil-cpp-" + version("ABSL")
        build_case(tmp, "ABSL", "abseil", absl, ".tar.gz",
                   "# Installer et compiler Abseil si nécessaire.\n", "# Installer et compiler RE2",
                   ["CMakeLists.txt", "absl/base/config.h"],
                   ["build/abseil/install/" + p for p in ("lib/cmake/absl/abslConfig.cmake", "include/absl/base/config.h", "lib/libabsl_base.a")] +
                   ["build/abseil/cmake-build/stub-output"])
        re2 = "re2-" + version("RE2")
        build_case(tmp, "RE2", "re2", re2, ".tar.gz",
                   "# Installer et compiler RE2 si nécessaire.\n", "# Compiler ncursesw localement.",
                   ["CMakeLists.txt", "re2/re2.h"],
                   ["build/re2/install/" + p for p in ("lib/cmake/re2/re2Config.cmake", "include/re2/re2.h", "lib/libre2.a")] +
                   ["build/re2/cmake-build/stub-output"])
        libarchive = "libarchive-" + version("LIBARCHIVE")
        build_case(tmp, "LIBARCHIVE", "libarchive", libarchive, ".tar.xz",
                   "# Installer et compiler libarchive si nécessaire.\n", "# Installer nlohmann/json",
                   ["CMakeLists.txt", "libarchive/archive.h", "libarchive/archive_entry.h"],
                   ["build/libarchive/cmake-build/libarchive/libarchive.a"])
        sqlite = "sqlite-amalgamation-" + version("SQLITE")
        build_case(tmp, "SQLITE", "sqlite", sqlite, ".zip",
                   "# Installer SQLite (amalgamation officielle, single-source) si nécessaire\n", "# Télécharger Lua",
                   ["sqlite3.c", "sqlite3.h"],
                   ["build/sqlite/" + sqlite + "/" + p for p in ("sqlite3.c", "sqlite3.h")])
    print(f"Dependency cache regression tests: {PASS} PASS / 0 FAIL")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError, IndexError, subprocess.TimeoutExpired) as error:
        print(f"[FAIL] dependency cache: {error}", file=sys.stderr)
        sys.exit(1)
