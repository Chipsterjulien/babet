-- Driven by XTest in test_gui_real_gtk.py: a day click focuses the Calendar,
-- then Ctrl+arrows exercise the toolkit's real month/year navigation signals.
local gui = babet.gui
assert(gui.init())
local window = assert(gui.window {
    title = "Babet real GTK calendar probe", width = 400, height = 360,
})
local root = assert(gui.box {orientation = "vertical", spacing = 0})
local calendar = assert(gui.calendar {year = 2024, month = 1, day = 1})
local frame = assert(gui.drawingArea {width = 1, height = 8})
assert(window:add(root))
assert(root:add(calendar))
assert(root:add(frame))
assert(calendar:setHExpand(true))
assert(calendar:setVExpand(true))
local function report(marker)
    io.stdout:write(marker .. "\n")
    io.stdout:flush()
end
local ready, focused, failure = false, false, nil
local calls = 0
local expected = {
    {2024, 2, 29}, {2024, 1, 29}, {2025, 1, 29},
    {2024, 1, 29}, {2023, 12, 29}, {2024, 1, 29},
}
local function checked(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            failure = failure or tostring(err)
            gui.quit()
        end
    end
end
assert(frame:onDraw(function()
    if not ready then
        ready = true
        report("REAL_GTK_CALENDAR_READY")
    end
end))
assert(calendar:onViewChanged(checked(function(...)
    assert(focused, "unexpected view callback before native navigation")
    assert(select("#", ...) == 0)
    calls = calls + 1
    local wanted = assert(expected[calls], "extra view callback")
    local y, m, d = calendar:getDate()
    assert(y == wanted[1] and m == wanted[2] and d == wanted[3],
        string.format("step %d: unexpected native date %04d-%02d-%02d", calls, y, m, d))
    assert(calendar:clearMarks())
    assert(calendar:markDay(m))
    assert(calendar:markDay(31))
    assert(calendar:unmarkDay(31))
    if calls == #expected then
        assert(window:close()) -- release parent from inside a real native signal
    end
    report("REAL_GTK_CALENDAR_STEP_" .. calls)
end)))
-- The center of this Calendar is a day cell, away from the header. Selecting
-- it grabs keyboard focus before day-selected is emitted. Acknowledge that
-- event instead of relying on a sleep or on the window manager's focus policy.
assert(calendar:onChanged(checked(function()
    assert(not focused)
    assert(calendar:onChanged(nil))
    assert(calendar:setDate(2024, 1, 31))
    assert(calls == 0, "programmatic setDate emitted onViewChanged")
    focused = true
    report("REAL_GTK_CALENDAR_FOCUSED")
end)))
assert(window:show())
assert(gui.run())
assert(not failure, failure)
assert(focused and calls == #expected, "missing native Calendar navigation callbacks")
print("REAL_GTK_CALENDAR_OK")
