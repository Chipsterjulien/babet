#!/usr/bin/env python3
"""DrawingArea regression: fake GTK lifecycle, optional real Cairo pixels."""
import ctypes.util
import os
from pathlib import Path
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(command, env=None):
    result = subprocess.run(command, env=env, text=True, capture_output=True,
                            stdin=subprocess.DEVNULL, timeout=60)
    if result.returncode:
        raise AssertionError(f"{command!r}: exit {result.returncode}\n"
                             f"{result.stdout[-3000:]}\n{result.stderr}")
    return result


def compile_fake(directory, source="fake_gtk4_runtime.c", extra=()):
    directory.mkdir()
    run([*shlex.split(os.environ.get("CC", "cc")), "-std=c99", "-Wall", "-Wextra", "-Werror",
         "-fPIC", "-shared", "-Wl,-soname,libgtk-4.so.1",
         str(ROOT / "tests/gui" / source), *extra,
         "-o", str(directory / "libgtk-4.so.1")])


def main():
    if len(sys.argv) != 2:
        raise AssertionError("usage: python3 tools/test_gui_drawing.py /path/to/babet")
    binary = str(Path(sys.argv[1]).resolve())
    passed = 0

    def success(message):
        nonlocal passed
        passed += 1
        print(f"[PASS] DrawingArea {message}")

    with tempfile.TemporaryDirectory(prefix="babet-gui-drawing-") as directory:
        temp = Path(directory)
        lib = temp / "lib"
        compile_fake(lib)
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("BABET_FAKE_", "BABET_CAIRO_"))}
        env.update(LD_LIBRARY_PATH=str(lib), BABET_FAKE_GTK_LOG=str(temp / "gtk.log"),
                   BABET_FAKE_CAIRO_LOG=str(temp / "cairo.log"))
        result = run([binary, str(ROOT / "tests/gui/drawing_contract.lua")], env)
        assert "DRAWING_CONTRACT_OK" in result.stdout
        assert "babet.gui callback error" not in result.stderr, result.stderr
        ops = (temp / "cairo.log").read_text().splitlines()
        for op in ["save", "restore", "new_path", "close_path", "stroke", "fill",
                   "move_to", "line_to", "rectangle", "arc", "set_line_width",
                   "set_source_rgb", "set_source_rgba", "set_font_size", "show_text"]:
            assert op in ops, op
        assert ops.count("save") == ops.count("restore") == 1
        assert (temp / "gtk.log").read_text().count("destroy:drawingArea") == 153
        success("types, primitives, finite numbers, UTF-8, expired contexts and GC cycles")

        project = temp / "project"
        project.mkdir()
        shutil.copyfile(ROOT / "tests/gui/drawing_events.lua", project / "main.lua")

        def events(command):
            log = temp / "events.log"
            log.unlink(missing_ok=True)
            result = run(command, dict(env, BABET_FAKE_GTK_LOG=str(log)))
            assert "DRAWING_EVENTS_OK" in result.stdout
            assert "DRAW_ERROR_SENTINEL" in result.stderr
            assert "yield" in result.stderr and "non-string Lua error" in result.stderr
            assert "REPLACED_DRAW_RAN" not in result.stderr
            assert "REMOVED_DRAW_RAN" not in result.stderr
            active = False
            lines = log.read_text().splitlines()
            for line in lines:
                if line == "draw-begin":
                    assert not active
                    active = True
                elif line == "draw-end":
                    assert active
                    active = False
                elif line.startswith("destroy:"):
                    assert not active, "native destruction inside GTK drawing stage"
            assert not active and "destroy:entry" in lines

        for mode, path in [("file", project / "main.lua"), ("folder", project)]:
            events([binary, str(path)])
            success(f"{mode}: redraw, callback errors/removal, parent ownership and deferred GC")
        app = temp / "drawing-app"
        run([binary, "--create-exe", str(project), str(app)])
        shutil.rmtree(project)
        events([str(app)])
        success("generated application runs after source removal")

        failure = temp / "failure.lua"
        failure.write_text('''
local gui = babet.gui
assert(gui.init())
local w = assert(gui.window())
local b = assert(gui.box())
local a = assert(gui.drawingArea())
local done = assert(gui.button("Done"))
assert(w:add(b)); assert(b:add(a)); assert(b:add(done))
local captured
assert(a:onDraw(function(ctx) captured = ctx; ctx:stroke(); error("UNREACHABLE") end))
assert(done:onClick(function() assert(gui.quit()) end))
assert(w:show()); assert(gui.run()); assert(w:close())
local ok, err = pcall(function() captured:stroke() end)
assert(not ok and tostring(err):find("only valid during", 1, true))
print("DRAWING_FAILURE_OK")
''')
        result = run([binary, str(failure)], dict(env, BABET_FAKE_CAIRO_FAIL="stroke"))
        assert "DRAWING_FAILURE_OK" in result.stdout
        assert "injected Cairo failure" in result.stderr and "UNREACHABLE" not in result.stderr
        success("Cairo failure is contained and invalidates the saved context")

        failure.write_text('''
assert(babet.gui.init())
for i = 1, 100 do
    local value, err = babet.gui.drawingArea()
    assert(value == nil and err:find("cannot attach", 1, true))
end
collectgarbage("collect")
print("DRAWING_CREATION_FAILURE_OK")
''')
        log = temp / "creation-failure.log"
        result = run([binary, str(failure)], dict(env, BABET_FAKE_GTK_FAIL_SIGNAL="destroy",
                                                BABET_FAKE_GTK_LOG=str(log)))
        assert "DRAWING_CREATION_FAILURE_OK" in result.stdout
        assert log.read_text().splitlines().count("destroy:drawingArea") == 100
        success("failed lifetime connection releases all 100 native widgets")

        probe = temp / "probe.lua"
        for macro, symbol in [("DRAWING", "gtk_drawing_area_new"), ("CAIRO", "cairo_show_text")]:
            missing = temp / f"missing-{macro}"
            compile_fake(missing, "fake_gtk4_good.c", [f"-DBABET_FAKE_GTK_MISSING_{macro}"])
            probe.write_text(f'''
local ok, err = babet.gui.available()
assert(ok == nil and err:find("{symbol}", 1, true), tostring(err))
local again, same = babet.gui.available()
assert(again == nil and same == err)
print("MISSING_SYMBOL_OK")
''')
            result = run([binary, str(probe)], dict(env, LD_LIBRARY_PATH=str(missing)))
            assert "MISSING_SYMBOL_OK" in result.stdout
            success(f"missing {symbol} produces a controlled, repeatable diagnostic")

        cairo = ctypes.util.find_library("cairo")
        fontconfig = ctypes.util.find_library("fontconfig")
        if cairo and fontconfig:
            real = temp / "real-cairo"
            compile_fake(real, extra=["-DBABET_TEST_REAL_CAIRO", f"-l:{cairo}", f"-l:{fontconfig}"])
            pixels = temp / "pixels.argb32"
            real_log = temp / "real-cairo.log"
            real_env = dict(env, LD_LIBRARY_PATH=str(real), BABET_CAIRO_PIXELS=str(pixels),
                            BABET_FAKE_GTK_LOG=str(real_log))
            result = run([binary, str(ROOT / "tests/gui/drawing_contract.lua")], real_env)
            assert "DRAWING_CONTRACT_OK" in result.stdout
            assert "babet.gui callback error" not in result.stderr, result.stderr
            raw = pixels.read_bytes()
            assert len(raw) == 200 * 100 * 4

            def pixel(x, y):
                return struct.unpack_from("=I", raw, 4 * (y * 200 + x))[0]

            assert pixel(190, 40) == 0xFFFFFFFF, hex(pixel(190, 40))
            assert pixel(20, 20) == 0xFFFF0000, hex(pixel(20, 20))
            assert pixel(70, 10) == 0xFF0000FF, hex(pixel(70, 10))
            assert pixel(80, 60) == 0xFF00FF00, hex(pixel(80, 60))
            assert any(pixel(x, y) != 0xFFFFFFFF for y in range(77, 91) for x in range(4, 90))
            assert real_log.read_text().splitlines().count("cairo-font-caches-released") == 1
            success("real Cairo: background, rectangle, stroke, arc, text and saved graphics state")

            real_log.unlink()
            result = run([binary, str(ROOT / "tests/gui/drawing_fonts.lua")], real_env)
            assert "DRAWING_FONTS_OK" in result.stdout
            assert "babet.gui callback error" not in result.stderr, result.stderr
            lines = real_log.read_text().splitlines()
            assert lines.count("draw-begin") == lines.count("draw-end") == 12
            assert lines.count("cairo-font-caches-released") == 12
            success("real Cairo: 12 text redraws with font-cache teardown and reinitialization")
        else:
            print("[SKIP] DrawingArea real Cairo pixels: system Cairo/Fontconfig runtimes are unavailable")
    print(f"GUI DrawingArea regression: {passed} PASS / 0 FAIL")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"[FAIL] GUI DrawingArea: {error}", file=sys.stderr)
        sys.exit(1)
