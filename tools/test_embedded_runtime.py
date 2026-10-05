#!/usr/bin/env python3
"""Behavioral regressions for the real CLI, packager and embedded workers."""
import argparse
import io
import os
from pathlib import Path
import selectors
import shlex
import shutil
import subprocess
import tempfile
import zipfile
from embedded_image_fixtures import marker_offset, replace_archive

LIMIT = 16 * 1024 * 1024
DIAGNOSTIC = "exceeds maximum embedded file size of 16 MiB"
ROOT = Path(__file__).resolve().parents[1]


def run(args, *, cwd, env=None, success=True):
    result = subprocess.run([str(x) for x in args], cwd=cwd, env=env,
                            capture_output=True, text=True, timeout=45)
    if success and result.returncode != 0:
        raise AssertionError(f"exit={result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


def wait_line(process, expected):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(15):
            raise AssertionError(f"no synchronization marker: {expected!r}")
        line = process.stdout.readline()
    if line != expected:
        raise AssertionError(f"synchronization: expected {expected!r}, got {line!r}")


def resumed(args, *, cwd, env, marker, change):
    with subprocess.Popen([str(x) for x in args], cwd=cwd, env=env,
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE) as process:
        try:
            wait_line(process, marker)
            change()
            stdout, stderr = process.communicate(b"G\n", timeout=30)
        except BaseException:
            process.kill()
            process.communicate()
            raise
        return process.returncode, stdout.decode(), stderr.decode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--only", choices=("loaders", "identity", "sizes"))
    args = parser.parse_args()
    binary = args.binary.resolve()
    passed = 0

    def check(label):
        nonlocal passed
        passed += 1
        print(f"[PASS] {label}", flush=True)

    with tempfile.TemporaryDirectory(prefix="babet-embedded-") as temp:
        base = Path(temp)
        isolated = base / "isolated"
        isolated.mkdir()

        def project(name, files):
            folder = base / name
            folder.mkdir()
            for name, data in files.items():
                path = folder / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data if isinstance(data, bytes) else data.encode())
            return folder

        def build(folder, name="application", builder=binary):
            output = base / name
            run([builder, "--create-exe", folder, output], cwd=isolated)
            return output

        if args.only in (None, "loaders"):
            prefixes = {"plain": b"", "shebang": b"#!/usr/bin/env babet\n",
                        "crlf": b"#!/usr/bin/env babet\r\n", "hash": b"# comment\n",
                        "bom": b"\xef\xbb\xbf",
                        "bom-shebang": b"\xef\xbb\xbf#!/usr/bin/env babet\n"}
            module = b'return "MODULE_OK"\n'
            files = {f"{name}.lua": prefix + module for name, prefix in prefixes.items()}
            files.update({"pkg/init.lua": prefixes["bom-shebang"] + module,
                          "empty.lua": b"", "bom_only.lua": prefixes["bom"],
                          "hash_only.lua": b"# no newline",
                          "bom_hash_only.lua": prefixes["bom"] + b"# no newline"})
            checks = "\n".join(f'assert(require("{name}") == "MODULE_OK")' for name in (*prefixes, "pkg"))
            checks += '\nfor _, n in ipairs({"empty", "bom_only", "hash_only", "bom_hash_only"}) do assert(require(n) == true) end\n'
            files["main.lua"] = (checks + 'local job = assert(babet.workers.spawn([==[\n' + checks +
                                 '\nreturn true]==])); local ok, v = job:join(10); assert(ok and v == true, tostring(v)); print("LOAD_OK")\n')
            folder = project("prefix-modules", files)
            assert run([binary, folder], cwd=isolated).stdout.strip() == "LOAD_OK"
            app = build(folder)
            shutil.rmtree(folder)
            assert run([app], cwd=isolated).stdout.strip() == "LOAD_OK"
            check("module prefixes, package/init.lua and empty files: disk/embedded/main/worker")

            # Make bytecode using this exact Lua runtime and architecture.
            dumper = project("dumper", {"main.lua": '''local file = assert(io.open(arg[1], "wb"))
assert(file:write(string.dump(function() print("MAIN_OK") end)))
assert(file:close())
local file2 = assert(io.open(arg[2], "wb"))
assert(file2:write(string.dump(function() return "MODULE_OK" end)))
assert(file2:close())
'''})
            main_bytecode, module_bytecode = base / "main.bin", base / "module.bin"
            run([binary, dumper, main_bytecode, module_bytecode], cwd=isolated)
            for name, prefix in prefixes.items():
                folder = project("main-" + name, {"main.lua": prefix + b'print("MAIN_OK")\n'})
                assert run([binary, folder], cwd=isolated).stdout.strip() == "MAIN_OK"
                app = build(folder)
                assert run([app], cwd=isolated).stdout.strip() == "MAIN_OK"
                check("main.lua prefix: " + name)
                folder = project("bytecode-" + name, {"main.lua": prefix + main_bytecode.read_bytes()})
                assert run([binary, folder], cwd=isolated).stdout.strip() == "MAIN_OK"
                app = build(folder)
                assert run([app], cwd=isolated).stdout.strip() == "MAIN_OK"
                check("bytecode main.lua prefix: " + name)
            files = {f"{name}.lua": prefix + module_bytecode.read_bytes() for name, prefix in prefixes.items()}
            files["main.lua"] = (checks.split('for _, n')[0].replace('assert(require("pkg") == "MODULE_OK")', '') +
                                 'local job = assert(babet.workers.spawn([[return require("bom-shebang")]])); '
                                 'local ok, v = job:join(10); assert(ok and v == "MODULE_OK", tostring(v)); print("BYTECODE_OK")')
            app = build(project("bytecode-modules", files))
            assert run([app], cwd=isolated).stdout.strip() == "BYTECODE_OK"
            check("bytecode module prefixes and worker require")

            for name, prefix in {"empty": b"", "bom": prefixes["bom"],
                                 "hash": b"# no newline", "bom-hash": prefixes["bom"] + b"#"}.items():
                app = build(project("empty-main-" + name, {"main.lua": prefix}))
                assert run([app], cwd=isolated).stdout == ""
                check("empty main.lua: " + name)

            # A shebang must not move an error from line 2 to line 1.
            bad = prefixes["bom-shebang"] + b"local =\n"
            folder = project("syntax-main", {"main.lua": bad})
            for command in ([binary, folder], [build(folder)]):
                result = run(command, cwd=isolated, success=False)
                assert result.returncode != 0 and ':2:' in result.stderr, result.stderr
            check("main.lua syntax diagnostic preserves line 2")
            folder = project("syntax-module", {"bad.lua": bad, "main.lua": '''
local ok, err = pcall(require, "bad")
assert(not ok and err:find(":2:", 1, true), tostring(err))
local job = assert(babet.workers.spawn([[local ok, err = pcall(require, "bad"); assert(not ok and err:find(":2:", 1, true), tostring(err)); return true]]))
local ok, v = job:join(10); assert(ok and v == true, tostring(v)); print("SYNTAX_OK")
'''})
            for command in ([binary, folder], [build(folder)]):
                assert run(command, cwd=isolated).stdout.strip() == "SYNTAX_OK"
            check("module and worker syntax diagnostics preserve line 2")
            for index, data in enumerate((b"\xef", b"\xef\xbb", b"\xef\xbbXreturn true", b"\xef\xbb\xbf\xef\xbb\xbfreturn true")):
                folder = project(f"bad-bom-{index}", {"main.lua": data})
                for command in ([binary, folder], [build(folder)]):
                    assert run(command, cwd=isolated, success=False).returncode != 0
            check("partial and repeated BOMs remain syntax errors")

        if args.only in (None, "identity", "sizes"):
            hook = base / "pause-open.so"
            compiler = shlex.split(os.environ.get("CC", "cc"))
            run([*compiler, "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror",
                 ROOT / "tests/embedded/pause_open.c", "-ldl", "-o", hook], cwd=isolated)

            def hook_env(path):
                env = os.environ.copy()
                libs = [os.environ.get("BABET_TEST_ASAN_RUNTIME", ""), str(hook), env.get("LD_PRELOAD", "")]
                env["LD_PRELOAD"] = ":".join(x for x in libs if x)
                env["BABET_TEST_PAUSE_OPEN"] = str(path)
                return env

        if args.only in (None, "identity"):
            identity_main = '''
assert(require("early") == "OLD")
local job = assert(babet.workers.spawn([[assert(require("early") == "OLD"); worker.send("READY"); assert(worker.recv(10)); return require("late")]]))
local received, message = job:recv(10); assert(received and message == "READY", tostring(message))
print("IDENTITY_READY"); io.stdout:flush(); assert(io.read("*l"))
assert(require("late") == "OLD")
assert(job:send("GO")); local ok, v = job:join(10); assert(ok and v == "OLD", tostring(v))
local next_job = assert(babet.workers.spawn([[return require("late")]]))
local ok, v = next_job:join(10); assert(ok and v == "OLD", tostring(v))
print("IDENTITY_OK")
'''
            for action in ("replace", "unlink"):
                folder = project("identity-" + action, {"main.lua": identity_main, "early.lua": 'return "OLD"', "late.lua": 'return "OLD"'})
                app = build(folder, "identity-app")
                replacement = build(project("replacement-" + action, {"main.lua": 'print("NEW")', "late.lua": 'return "NEW"'}), "replacement")
                shutil.rmtree(folder)
                change = (lambda: os.replace(replacement, app)) if action == "replace" else app.unlink
                code, out, err = resumed([app], cwd=isolated, env=None, marker=b"IDENTITY_READY\n", change=change)
                assert code == 0 and out.strip() == "IDENTITY_OK", (code, out, err)
                check(f"running image after {action}: main, existing worker, new worker")

            original = binary.read_bytes()
            for action in ("replace", "unlink"):
                builder = base / "builder-copy"
                shutil.copy2(binary, builder)
                builder.chmod(0o755)
                folder = project("builder-" + action, {"main.lua": 'print("BUILDER_OK")'})
                output = base / "builder-app"
                replacement = base / "not-an-executable"
                replacement.write_bytes(b"WRONG_INODE")
                change = (lambda: os.replace(replacement, builder)) if action == "replace" else builder.unlink
                code, out, err = resumed([builder, "-c", folder, output], cwd=isolated,
                                        env=hook_env(folder / "main.lua"), marker=b"BABET_OPEN_READY\n", change=change)
                assert code == 0, (code, out, err)
                with output.open("rb") as file:
                    prefix = file.read(len(original))
                    marker = marker_offset(original)
                    assert (prefix[:marker] == original[:marker] and
                            prefix[marker + 64:] == original[marker + 64:]), "packager copied another inode"
                assert run([output], cwd=isolated).stdout.strip() == "BUILDER_OK"
                check(f"packager copies its running image after {action}")

        if args.only in (None, "sizes"):
            def lua_size(size, tail=b"\nreturn true\n"):
                return b"--" + b"x" * (size - 2 - len(tail)) + tail

            for name in ("main.lua", "huge.lua", "nested/huge.lua", "pkg/init.lua"):
                folder = project("limit-" + name.replace("/", "-"), {"main.lua": 'print("SIZE_OK")', name: lua_size(LIMIT + 1)})
                for exists in (False, True):
                    output = base / "limit-app"
                    if output.exists(): output.unlink()
                    if exists:
                        output.write_bytes(b"PREVIOUS_APPLICATION")
                        output.chmod(0o751)
                    before = output.stat() if exists else None
                    result = run([binary, "-c", folder, output], cwd=isolated, success=False)
                    assert result.returncode != 0 and DIAGNOSTIC in result.stderr and name in result.stderr, result
                    if exists:
                        assert output.read_bytes() == b"PREVIOUS_APPLICATION"
                        assert output.stat().st_ino == before.st_ino and output.stat().st_mode == before.st_mode
                    else:
                        assert not output.exists()
                check(f"reject {name} >16 MiB before publication; preserve previous output")
            folder = project("exact-limit", {"main.lua": lua_size(LIMIT, b'\nassert(require("module") == true)\n'), "module.lua": lua_size(LIMIT), "large-asset.dat": b"x" * (LIMIT + 1)})
            app = build(folder)
            run([app], cwd=isolated)
            with zipfile.ZipFile(app) as archive:
                assert archive.getinfo("module.lua").file_size == LIMIT
                assert archive.getinfo("large-asset.dat").file_size == LIMIT + 1
            check("exactly 16 MiB scripts and larger non-Lua assets remain accepted")

            # Forged marked archives still need the runtime limit. A module
            # failure must not fall through to a same-named disk module.
            for target in ("main.lua", "huge.lua"):
                archive = io.BytesIO()
                with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zipout:
                    zipout.writestr("main.lua", lua_size(LIMIT + 1) if target == "main.lua" else b'require("huge")')
                    if target != "main.lua": zipout.writestr(target, lua_size(LIMIT + 1))
                app = base / "legacy-oversized"
                app.write_bytes(replace_archive(binary.read_bytes(), archive.getvalue()))
                app.chmod(0o755)
                (isolated / "huge.lua").write_text('print("WRONG_DISK_FALLBACK")')
                result = run([app], cwd=isolated, success=False)
                assert result.returncode != 0 and DIAGNOSTIC in result.stderr and "WRONG_DISK" not in result.stdout
                check("runtime still rejects oversized marked archive: " + target)

            for nested in (False, True):
                # The long name also exercises full ZIP names beyond the
                # fixed-size miniz file_stat filename field.
                name = ("nested" + "x" * 94 + "/") * 6 + "grow.lua" if nested else "grow.lua"
                folder = project("growing-" + str(nested), {"main.lua": "return true", name: "return true"})
                output = base / "growing-app"
                output.write_bytes(b"OLD")
                code, out, err = resumed([binary, "-c", folder, output], cwd=isolated,
                                        env=hook_env(folder / name), marker=b"BABET_OPEN_READY\n",
                                        change=lambda: (folder / name).write_bytes(lua_size(LIMIT + 1)))
                assert code != 0 and DIAGNOSTIC in err and name in err, (code, out, err)
                assert output.read_bytes() == b"OLD"
                check("completed archive rejects source growth" + (" with long path" if nested else ""))

    print(f"embedded runtime: {passed} PASS / 0 FAIL")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"[FAIL] embedded runtime: {error}", flush=True)
        raise SystemExit(1)
