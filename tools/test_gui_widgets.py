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
    sanitizer_mode = os.environ.get("BABET_TEST_GUI_SANITIZERS", "OFF")
    sanitizer_flags = {
        "OFF": [],
        "UBSAN": ["-fsanitize=undefined", "-fno-omit-frame-pointer"],
        "ASAN_UBSAN": ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"],
    }[sanitizer_mode]

    def success(message):
        passed.append(message)
        print(f"[PASS] {message}")

    with tempfile.TemporaryDirectory(prefix="babet-gui-widgets-") as directory:
        temp = Path(directory)
        def compile_fake(directory, extra=()):
            directory.mkdir()
            run([*shlex.split(os.environ.get("CC", "cc")), "-std=c99", "-Wall", "-Wextra", "-Werror",
                 "-fPIC", "-shared", "-Wl,-soname,libgtk-4.so.1", *sanitizer_flags, *extra,
                 str(ROOT / "tests/gui/fake_gtk4_runtime.c"),
                 "-o", str(directory / "libgtk-4.so.1")])

        lib = temp / "lib"
        compile_fake(lib)
        log_path = temp / "gtk.log"
        env = dict(os.environ, LD_LIBRARY_PATH=str(lib), BABET_FAKE_GTK_LOG=str(log_path))
        env.pop("BABET_FAKE_GTK_FAIL_SIGNAL", None)
        env.pop("BABET_FAKE_GTK_CALENDAR_EVENTS", None)
        env.pop("BABET_CALENDAR_CASE", None)
        for key in list(env):
            if key.startswith("BABET_FAKE_GTK_DND_"):
                env.pop(key)
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

        for mode in ("cycles", "lifetime"):
            result = run([binary, str(ROOT / "tests/gui/popover_ownership.lua"), mode], env)
            assert f"GUI_POPOVER_OWNERSHIP_OK:{mode}" in result.stdout
            assert not result.stderr.strip(), result.stderr
            success(f"popover ownership: {mode}")

        for mode in ("copy-at-drop", "move-at-drop", "copy", "move", "link", "copy-only", "link-only", "drop-false", "drop-error", "reject-then-move"):
            result = run([binary, str(ROOT / "tests/gui/native_dnd_actions.lua"), mode],
                         dict(env, BABET_FAKE_GTK_DND_HIT="target", BABET_FAKE_GTK_DND_FINISHED_ON_REJECT="1",
                              BABET_FAKE_GTK_DND_GESTURES="2" if mode == "reject-then-move" else "1"))
            assert f"REAL_GTK_DND_OK:{mode}" in result.stdout
            if mode in ("copy-at-drop", "move-at-drop"):
                assert "cannot change the negotiated action during drop" in result.stderr, result.stderr
            elif mode == "drop-error":
                assert "DND_FINAL_ERROR_SENTINEL" in result.stderr, result.stderr
            else:
                assert not result.stderr.strip(), result.stderr
            success(f"DND action and source deletion: {mode}")

        for mode in ("unparented", "mapped", "hidden", "detached", "destroyed", "reset"):
            icon_log = temp / f"drag-icon-{mode}.log"
            result = run([binary, str(ROOT / "tests/gui/native_dnd_icon.lua"), mode],
                         dict(env, BABET_FAKE_GTK_DND_HIT="target", BABET_FAKE_GTK_LOG=str(icon_log)))
            assert f"GUI_DND_ICON_OK:{mode}" in result.stdout, result.stdout
            assert not result.stderr.strip(), result.stderr
            lines = icon_log.read_text().splitlines()
            expected_icon = "custom-preview" if mode == "mapped" else "visible-source"
            assert f"dnd-icon-widget:{expected_icon}" in lines, lines
            assert sum(line.startswith("widget-paintable:") for line in lines) == lines.count("destroy:widgetPaintable"), lines
            success(f"drag icon mapping and native cleanup: {mode}")

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

        dnd_log = temp / "native-dnd.log"
        dnd_env = dict(env, BABET_FAKE_GTK_LOG=str(dnd_log))
        dnd_result = run([binary, str(ROOT / "tests/gui/native_dnd_contract.lua")], dnd_env)
        assert "GUI_NATIVE_DND_CONTRACT_OK" in dnd_result.stdout
        dnd_lines = dnd_log.read_text().splitlines()
        assert "dnd-complete:row-42" in dnd_lines
        assert "dnd-icon-widget:visible-handle" in dnd_lines
        assert dnd_lines.count("widget-paintable:drag-handle") == 1
        assert dnd_lines.count("destroy:widgetPaintable") == 1
        success("native GtkDragSource/GtkDropTarget string DND lifecycle")

        # Explicit false and callback errors are both rejection paths, never
        # process-aborting native failures. The error is reported and contained.
        for mode, rejected_marker, stderr_marker in (
            ("drop-false", "dnd-rejected:drop", None),
            ("enter-error", "dnd-rejected:drop", "DND_ERROR_SENTINEL"),
        ):
            reject_log = temp / f"native-dnd-reject-{mode}.log"
            reject_env = dict(env, BABET_FAKE_GTK_LOG=str(reject_log))
            rejected = run([binary, str(ROOT / "tests/gui/native_dnd_reject.lua"), mode], reject_env)
            assert f"GUI_NATIVE_DND_REJECT_OK:{mode}" in rejected.stdout
            reject_text = reject_log.read_text()
            assert rejected_marker in reject_text, reject_text
            assert "dnd-complete:" not in reject_text, reject_text
            if stderr_marker:
                assert stderr_marker in rejected.stderr, rejected.stderr
            else:
                assert not rejected.stderr.strip(), rejected.stderr
            success(f"native DND rejection is contained: {mode}")

        desktop_log = temp / "desktop-ui.log"
        desktop_env = dict(
            env, BABET_FAKE_GTK_LOG=str(desktop_log),
            BABET_FAKE_GTK_DESKTOP_EVENTS="1",
            BABET_FAKE_GTK_DND_MODIFIERS="4",
        )
        desktop = run([binary, str(ROOT / "tests/gui/desktop_ui_contract.lua")], desktop_env)
        assert "GUI_DESKTOP_UI_CONTRACT_OK" in desktop.stdout, desktop.stdout
        assert not desktop.stderr.strip(), desktop.stderr
        desktop_lines = desktop_log.read_text().splitlines()
        for marker in (
            "cursor:grab", "tooltip:Move note", "text-wrap",
            "paned-start:set:slot-a", "paned-end:set:slot-b",
            "paned-start:clear", "paned-end:clear",
            "paned-start:set:slot-b", "paned-end:set:slot-c",
            "window-transient:set", "window-modal:1",
            "menu-popup", "menu-popdown", "widget-parent:set:", "widget-parent:clear:", "popover-present",
            "popover-popup", "popover-popdown", "popover-point",
            "key-consumed:1", "controller-phase:1", "close-request-blocked:1",
            "dnd-icon-widget:drag-preview", "dnd-hover:enter:copy",
            "dnd-hover:motion:copy", "dnd-complete:desktop-row",
        ):
            assert marker in desktop_lines, (marker, desktop_lines[-100:])
        success("desktop UI primitives, context popovers and rich DND")

        for mode in (
            "disabled", "reenabled", "self-disable-enter", "self-disable-drop",
            "toggle-enter", "clear-source", "replace-source", "replace-callback",
            "close-enter", "close-drop", "close-leave", "hover-recover",
            "hover-false", "hover-false-alone", "hover-yield", "delayed", "cancel",
        ):
            lifecycle_log = temp / f"dnd-lifecycle-{mode}.log"
            lifecycle_env = dict(env, BABET_FAKE_GTK_LOG=str(lifecycle_log),
                                 BABET_FAKE_GTK_DND_HIT="dnd-hit")
            if mode == "toggle-enter":
                lifecycle_env["BABET_FAKE_GTK_DND_GESTURES"] = "2"
            if mode == "delayed":
                lifecycle_env["BABET_FAKE_GTK_DND_DELAYED"] = "1"
            if mode in ("cancel", "close-leave"):
                lifecycle_env["BABET_FAKE_GTK_DND_CANCEL"] = "1"
            result = run([binary, str(ROOT / "tests/gui/native_dnd_lifecycle.lua"), mode], lifecycle_env)
            assert f"GUI_NATIVE_DND_LIFECYCLE_OK:{mode}" in result.stdout, result.stdout
            lines = lifecycle_log.read_text().splitlines()
            assert lines.count("destroy:dropTarget") == 102, "DND native controller leak"
            assert lines.count("destroy:widgetPaintable") == 101, "DND icon reference leak"
            if mode in ("self-disable-drop", "hover-false"):
                assert any(x.startswith("dnd-rejected:drop:") for x in lines), lines
                assert not any(x.startswith("dnd-complete:") for x in lines), lines
            elif mode in ("cancel", "close-enter", "close-leave", "hover-false-alone"):
                assert any(x.startswith("dnd-cancelled:") for x in lines), lines
            else:
                assert any(x.startswith("dnd-complete:") for x in lines), lines
            if mode == "hover-yield":
                assert "yield" in result.stderr, result.stderr
            else:
                assert not result.stderr.strip(), result.stderr
            success(f"native DND lifetime and propagation: {mode}")

        icon_failure = temp / "icon-failure.lua"
        icon_failure.write_text("""
assert(babet.gui.init())
for i = 1, 100 do
    local handle = assert(babet.gui.label("handle"))
    local ok, err = handle:setDragData("internal-id")
    assert(ok == nil and err:find("cannot create GTK drag icon", 1, true))
    assert(handle:setDragData(nil))
    handle = nil
    collectgarbage("collect")
end
print("ICON_FAILURE_OK")
""")
        icon_log = temp / "icon-failure.log"
        result = run([binary, str(icon_failure)], dict(
            env, BABET_FAKE_GTK_DND_FAIL_ICON="1", BABET_FAKE_GTK_LOG=str(icon_log)))
        assert "ICON_FAILURE_OK" in result.stdout and not result.stderr.strip()
        assert icon_log.read_text().splitlines().count("destroy:dragSource") == 100
        success("drag icon allocation failure releases unattached source")

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

        # A lazy GtkDropTarget that fails while wiring any signal must
        # release the controller and every closure already connected to it.
        bad_drop_script = temp / "fail-drop-target.lua"
        bad_drop_script.write_text("""
assert(babet.gui.init())
for i = 1, 100 do
    local target = assert(babet.gui.label("target"))
    local result, err = target:onDrop(function() end)
    assert(result == nil and type(err) == "string" and err:find("cannot attach", 1, true), tostring(err))
    target = nil
    collectgarbage("collect")
end
print("GUI_DROP_TARGET_FAILURE_OK")
""")
        for signal in ("enter", "motion", "leave", "drop"):
            drop_failure_log = temp / f"failure-drop-target-{signal}.log"
            drop_failure_env = dict(env, BABET_FAKE_GTK_FAIL_SIGNAL=signal,
                                    BABET_FAKE_GTK_LOG=str(drop_failure_log))
            failed = run([binary, str(bad_drop_script)], drop_failure_env)
            assert "GUI_DROP_TARGET_FAILURE_OK" in failed.stdout
            assert drop_failure_log.read_text().splitlines().count("destroy:dropTarget") == 100
            success(f"dropTarget {signal} signal failure releases native resources")

        # New desktop controllers/signals are lazy. Any partial connection
        # failure must destroy the unattached controller and leave the widget
        # itself collectable; no callback/state reference may leak.
        desktop_failures = (
            ("pressed", "pointer-press", "label", "onPointer",
             ("destroy:label", "destroy:gestureClick", "destroy:pointerMotion")),
            ("released", "pointer-release", "label", "onPointer",
             ("destroy:label", "destroy:gestureClick", "destroy:pointerMotion")),
            ("enter", "pointer-enter", "label", "onPointer",
             ("destroy:label", "destroy:gestureClick", "destroy:pointerMotion")),
            ("motion", "pointer-motion", "label", "onPointer",
             ("destroy:label", "destroy:gestureClick", "destroy:pointerMotion")),
            ("leave", "pointer-leave", "label", "onPointer",
             ("destroy:label", "destroy:gestureClick", "destroy:pointerMotion")),
            ("key-pressed", "key-press", "label", "onKey",
             ("destroy:label", "destroy:keyController")),
            ("key-released", "key-release", "label", "onKey",
             ("destroy:label", "destroy:keyController")),
            ("notify::position", "paned", "paned", "onPositionChanged",
             ("destroy:paned",)),
            ("close-request", "close", "window", "onCloseRequest",
             ("destroy:window",)),
            ("drag-begin", "drag-begin", "label", "drag-source",
             ("destroy:label", "destroy:dragSource", "destroy:widgetPaintable")),
            ("drag-end", "drag-end", "label", "drag-source",
             ("destroy:label", "destroy:dragSource", "destroy:widgetPaintable")),
            ("drag-cancel", "drag-cancel", "label", "drag-source",
             ("destroy:label", "destroy:dragSource", "destroy:widgetPaintable")),
        )
        for signal, label, constructor, method, destroyed_markers in desktop_failures:
            script = temp / f"fail-desktop-{label}.lua"
            if constructor == "paned":
                create = "assert(babet.gui.paned())"
            elif constructor == "window":
                create = "assert(babet.gui.window())"
            else:
                create = "assert(babet.gui.label('desktop'))"
            if method == "drag-source":
                operation = "widget:setDragData('row')"
            else:
                operation = f"widget:{method}(function() end)"
            lua_source = (
                "assert(babet.gui.init())\n"
                "for i = 1, 100 do\n"
                f"    local widget = {create}\n"
                f"    local ok, err = {operation}\n"
                "    assert(ok == nil and type(err) == 'string' and err:find('cannot attach', 1, true), tostring(err))\n"
                "    if widget.close then pcall(function() widget:close() end) end\n"
                "    widget = nil\n"
                "    collectgarbage('collect')\n"
                "end\n"
                "print('GUI_DESKTOP_SIGNAL_FAILURE_OK')\n"
            )
            script.write_text(lua_source)
            failure_log = temp / f"failure-desktop-{label}.log"
            failure_env = dict(env, BABET_FAKE_GTK_FAIL_SIGNAL=signal,
                               BABET_FAKE_GTK_LOG=str(failure_log))
            failed = run([binary, str(script)], failure_env)
            assert "GUI_DESKTOP_SIGNAL_FAILURE_OK" in failed.stdout
            lines = failure_log.read_text().splitlines()
            for destroyed in destroyed_markers:
                assert lines.count(destroyed) == 100, (signal, destroyed, lines[-50:])
            success(f"desktop {label} signal failure releases native resources")

    print(f"GUI widgets regression: {len(passed)} PASS / 0 FAIL")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, KeyError, OSError, subprocess.SubprocessError) as error:
        print(f"[FAIL] GUI widgets: {error}", file=sys.stderr)
        sys.exit(1)
