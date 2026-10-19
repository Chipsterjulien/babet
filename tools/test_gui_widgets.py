#!/usr/bin/env python3
"""GUI lots 3-6 contracts using a fake GTK DSO; no GTK headers/display required."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(command, env=None):
    result = subprocess.run(command, env=env, text=True, capture_output=True,
                            stdin=subprocess.DEVNULL, timeout=60)
    if result.returncode:
        raise AssertionError(f"{command!r}: exit {result.returncode}\n"
                             f"{result.stdout[-5000:]}\n{result.stderr[-8000:]}")
    return result


def main():
    if len(sys.argv) != 2:
        raise AssertionError("usage: python3 tools/test_gui_widgets.py /path/to/babet")
    binary = str(Path(sys.argv[1]).resolve())
    passed = []

    def success(message):
        passed.append(message)
        print(f"[PASS] {message}")

    with tempfile.TemporaryDirectory(prefix="babet-gui-widgets-") as directory:
        temp = Path(directory)
        def compile_fake(directory, extra=()):
            directory.mkdir()
            run([*shlex.split(os.environ.get("CC", "cc")), "-std=c99", "-Wall", "-Wextra", "-Werror",
                 "-fPIC", "-shared", "-Wl,-soname,libgtk-4.so.1", *extra,
                 str(ROOT / "tests/gui/fake_gtk4_runtime.c"),
                 "-o", str(directory / "libgtk-4.so.1")])

        lib = temp / "lib"
        compile_fake(lib)
        log_path = temp / "gtk.log"
        env = dict(os.environ, LD_LIBRARY_PATH=str(lib), BABET_FAKE_GTK_LOG=str(log_path))
        env.pop("BABET_FAKE_GTK_FAIL_SIGNAL", None)
        env.pop("BABET_FAKE_GTK_CALENDAR_EVENTS", None)
        env.pop("BABET_CALENDAR_CASE", None)
        result = run([binary, str(ROOT / "tests/gui/widgets_contract.lua")], env)
        assert "GUI_WIDGETS_CONTRACT_OK" in result.stdout
        assert "SPIN_CHANGED_ERROR_SENTINEL" in result.stderr
        assert "CALENDAR_CHANGED_ERROR_SENTINEL" in result.stderr
        assert "yield" in result.stderr
        log = log_path.read_text()
        for marker in [
            "box-remove", "scrolled-child:set", "scrolled-child:clear",
            "spin-after-change", "calendar-after-change",
            "calendar-clear-marks", "calendar-mark:7", "calendar-mark:29",
            "calendar-unmark:7",
            "margin-top", "margin-end", "margin-bottom", "margin-start",
            "hexpand:true", "vexpand:true", "visible:false", "sensitive:false",
            "css-load-string:", "css-provider:add", "css-provider:remove",
            "css-class:add:app-card", "css-class:add:primary",
            "css-class:remove:primary",
        ]:
            assert marker in log, marker
        assert "css-load-data:" not in log, "modern CSS API should be preferred when available"
        success("containers, widgets, CSS styling and common properties")

        for fixture, marker in (
            ("free_layout_contract.lua", "GUI_FREE_LAYOUT_CONTRACT_OK"),
            ("free_layout_drag.lua", "GUI_FREE_LAYOUT_DRAG_OK"),
        ):
            result = run([binary, str(ROOT / "tests/gui" / fixture)], env)
            assert marker in result.stdout, (fixture, result.stdout)
            success(f"{fixture}: free layout, cycle guards and drag coordinates")

        native_log = temp / "native-widgets.log"
        native_env = dict(env, BABET_FAKE_GTK_LOG=str(native_log))
        native_result = run([binary, str(ROOT / "tests/gui/native_list_contract.lua")], native_env)
        assert "GUI_NATIVE_LIST_CONTRACT_OK" in native_result.stdout
        native_text = native_log.read_text()
        assert native_text.count("box-reorder:") == 4, native_text
        removals = [line for line in native_text.splitlines() if line.startswith("box-remove:")]
        assert removals == [
            "box-remove:row-d",       # explicit remove() before re-adding row-d
            "box-remove:row-d",       # clear(): logical Lua order must match GTK
            "box-remove:row-c",
            "box-remove:row-b",
            "box-remove:row-a",
        ], native_text
        orders = [line for line in native_text.splitlines() if line.startswith("box-order:")]
        assert orders == [
            "box-order:row-a,row-d,row-b,row-c",
            "box-order:row-d,row-b,row-c,row-a",
            "box-order:row-c,row-d,row-b,row-a",
            "box-order:row-d,row-c,row-b,row-a",
        ], native_text
        success("native GtkBox reorder order and GtkProgressBar click progression")

        # GTK 4.0-4.10 do not provide gtk_css_provider_load_from_string().
        # The loader must retain the data API as a compatibility fallback.
        fallback_lib = temp / "fallback-lib"
        compile_fake(fallback_lib, ["-DBABET_FAKE_GTK_MISSING_CSS_STRING"])
        fallback_log = temp / "fallback-css.log"
        fallback_script = temp / "fallback-css.lua"
        fallback_script.write_text(
            'assert(babet.gui.init())\n'
            'assert(babet.gui.setCss(".fallback { padding: 1px; }"))\n'
            'assert(babet.gui.setCss(nil))\n'
            'print("GUI_CSS_FALLBACK_OK")\n'
        )
        fallback_env = dict(env, LD_LIBRARY_PATH=str(fallback_lib),
                            BABET_FAKE_GTK_LOG=str(fallback_log))
        result = run([binary, str(fallback_script)], fallback_env)
        assert "GUI_CSS_FALLBACK_OK" in result.stdout
        fallback_text = fallback_log.read_text()
        assert "css-load-data:" in fallback_text
        assert "css-load-string:" not in fallback_text
        success("CSS loader prefers GTK 4.12 string API and falls back on older GTK4")

        # Exercise native signals, not setters that bypass onViewChanged.
        navigation = "next-month,prev-month,next-year,prev-year,prev-month,next-month"
        for case, events in (
            ("navigation", navigation),
            ("replacement", "next-month,next-month,next-month"),
            ("error", "next-month,next-month"),
            ("yield", "next-month,next-month"),
            ("reentrant", "next-month,next-month"),
            ("close", "next-month"),
        ):
            calendar_log = temp / f"calendar-{case}.log"
            calendar_env = dict(env, BABET_FAKE_GTK_LOG=str(calendar_log),
                                BABET_CALENDAR_CASE=case,
                                BABET_FAKE_GTK_CALENDAR_EVENTS=events)
            result = run([binary, str(ROOT / "tests/gui/calendar_view_contract.lua")], calendar_env)
            assert f"GUI_CALENDAR_VIEW_OK:{case}" in result.stdout, result.stdout
            lines = calendar_log.read_text().splitlines()
            actual_events = [line for line in lines if line.startswith("calendar-view-event:")]
            assert len(actual_events) == len(events.split(",")), actual_events
            assert [line.split(":")[1] for line in actual_events] == events.split(","), actual_events
            if case == "navigation":
                marks = [line.split(":")[1] for line in lines
                         if line.startswith("calendar-marks-after-view:")]
                assert marks == ["00000002", "00000001", "00000001",
                                 "00000001", "00000800", "00000001"], marks
                assert lines.count("destroy:calendar") == 51, "Calendar cycle/native leak"
                assert lines.count("closure-notify:calendar-view") == 51 * 4
            else:
                assert lines.count("destroy:calendar") == 1, "Calendar native leak"
                assert lines.count("closure-notify:calendar-view") == 4
            if case == "error":
                assert result.stderr.count("CALENDAR_VIEW_ERROR_SENTINEL") == 1, result.stderr
            elif case == "yield":
                assert "yield" in result.stderr, result.stderr
            else:
                assert not result.stderr.strip(), result.stderr
            success(f"Calendar native navigation: {case}")

        # A signal connection failure must release the construction reference.
        cases = [
            ("value-changed", "spinButton", "destroy:spinButton"),
            ("day-selected", "calendar", "destroy:calendar"),
            ("next-month", "calendar", "destroy:calendar"),
            ("prev-month", "calendar", "destroy:calendar"),
            ("next-year", "calendar", "destroy:calendar"),
            ("prev-year", "calendar", "destroy:calendar"),
        ]
        for signal, constructor, destroyed in cases:
            script = temp / f"fail-{constructor}.lua"
            script.write_text(f'''\nassert(babet.gui.init())\nfor i = 1, 100 do\n    local widget, err = babet.gui.{constructor}()\n    assert(widget == nil and type(err) == "string" and err:find("cannot attach", 1, true), tostring(err))\nend\ncollectgarbage("collect")\nprint("GUI_SIGNAL_FAILURE_OK")\n''')
            failure_log = temp / f"failure-{signal}.log"
            failure_env = dict(env, BABET_FAKE_GTK_FAIL_SIGNAL=signal,
                               BABET_FAKE_GTK_LOG=str(failure_log))
            result = run([binary, str(script)], failure_env)
            assert "GUI_SIGNAL_FAILURE_OK" in result.stdout
            assert failure_log.read_text().splitlines().count(destroyed) == 100
            success(f"{constructor} {signal} connection failure releases native resources")

        # A failure while adding a lazy click gesture leaves the existing
        # progressBar handle alive and does not retain native controllers.
        bad_gesture_script = temp / "fail-progress-click.lua"
        bad_gesture_script.write_text("""
assert(babet.gui.init())
for i = 1, 100 do
    local bar = assert(babet.gui.progressBar())
    local result, err = bar:onClick(function() end)
    assert(result == nil and type(err) == "string" and err:find("cannot attach", 1, true), tostring(err))
    bar = nil
    collectgarbage("collect")
end
print("GUI_PROGRESS_CLICK_FAILURE_OK")
""")
        failure_log = temp / "failure-progress-click.log"
        failure_env = dict(env, BABET_FAKE_GTK_FAIL_SIGNAL="pressed",
                           BABET_FAKE_GTK_LOG=str(failure_log))
        failed = run([binary, str(bad_gesture_script)], failure_env)
        assert "GUI_PROGRESS_CLICK_FAILURE_OK" in failed.stdout
        assert failure_log.read_text().splitlines().count("destroy:progressBar") == 100
        success("progressBar lazy click gesture failure releases native resources")

    print(f"GUI widgets regression: {len(passed)} PASS / 0 FAIL")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f"[FAIL] GUI widgets: {error}", file=sys.stderr)
        sys.exit(1)
