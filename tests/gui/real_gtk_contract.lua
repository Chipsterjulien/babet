local gui = babet.gui
assert(gui.init())

local window = assert(gui.window {title = "Babet real GTK probe", width = 320, height = 240})
local root = assert(gui.box {orientation = "vertical", spacing = 4})
assert(window:add(root))

-- Exercise real container ownership/reparenting paths.
local scrolled = assert(gui.scrolledWindow())
local label = assert(gui.label("history"))
assert(root:add(scrolled))
assert(scrolled:add(label))
assert(scrolled:remove(label))
assert(root:add(label))
assert(root:remove(label))
assert(scrolled:add(label))
assert(scrolled:clear())
assert(root:add(label))
-- Native in-place reorder: no GTK child detach, no destroyed handle.
local ordered_a, ordered_b = assert(gui.label("ordered-a")), assert(gui.label("ordered-b"))
assert(root:add(ordered_a))
assert(root:add(ordered_b))
assert(root:reorder(ordered_b, label))
assert(root:reorder(ordered_a, ordered_b))
assert(root:reorder(ordered_a, nil))
assert(root:remove(ordered_a))
assert(root:add(ordered_a))

-- Babet's public Entry:setText contract deliberately coalesces GTK's native
-- delete/insert notification burst into one final notification.
local entry = assert(gui.entry {text = "ancien"})
assert(root:add(entry))
local seen = {}
assert(entry:onChanged(function()
    seen[#seen + 1] = entry:getText()
end))
assert(entry:setText("nouveau"))
assert(#seen == 1 and seen[1] == "nouveau", table.concat(seen, "|"))
assert(entry:setText("nouveau"))
assert(#seen == 1, "identical setText must not emit onChanged")
assert(entry:setText(""))
assert(#seen == 2 and seen[2] == "", "empty final value must be reported once")

local spin = assert(gui.spinButton {min = 30, max = 250, step = 0.1, value = 75, digits = 1})
assert(root:add(spin))
local spin_changes = 0
assert(spin:onChanged(function() spin_changes = spin_changes + 1 end))
assert(spin:setValue(76.5))
assert(math.abs(spin:getValue() - 76.5) < 1e-9 and spin_changes >= 1)

local calendar = assert(gui.calendar {year = 2026, month = 10, day = 10})
assert(root:add(calendar))
local calendar_changes = 0
assert(calendar:onChanged(function() calendar_changes = calendar_changes + 1 end))
assert(calendar:setDate(2025, 12, 31))
assert(calendar:clearMarks())
assert(calendar:markDay(15))
assert(calendar:unmarkDay(15))
local year, month, day = calendar:getDate()
assert(year == 2025 and month == 12 and day == 31)
assert(calendar_changes >= 1)

-- A real collapsed GtkExpander keeps its child unparented. Babet must still
-- refuse cycles and double parenting through it; otherwise the next add loops
-- forever, or expanding raises a Gtk-CRITICAL (fatal under fatal-criticals).
local function refused(fn, fragment)
    local ok, err = pcall(fn)
    assert(not ok and tostring(err):find(fragment, 1, true), tostring(err))
end
local folded = assert(gui.expander {label = "replié"})
local folded_inner = assert(gui.box {orientation = "vertical"})
assert(folded:add(folded_inner))
refused(function() folded_inner:add(folded) end, "parent cycle")
assert(root:add(folded))
local single = assert(gui.expander {label = "simple"})
assert(root:add(single))
local only_child = assert(gui.label("un seul parent"))
assert(single:add(only_child))
local elsewhere = assert(gui.box())
assert(root:add(elsewhere))
refused(function() elsewhere:add(only_child) end, "already has a GTK parent")
assert(folded:setExpanded(true))
assert(single:setExpanded(true))
assert(folded_inner:add(assert(gui.label("ajout après dépliage"))))
assert(single:remove(only_child))
assert(elsewhere:add(only_child))
assert(single:setExpanded(false))
-- Reuse: back into the collapsed expander, then out while it is open.
assert(elsewhere:remove(only_child))
assert(single:add(only_child))
assert(single:setExpanded(true))
assert(single:remove(only_child))
assert(elsewhere:add(only_child))
-- Deep logical trees: no recursion limit and no false "parent cycle".
local deep = {assert(gui.box())}
for i = 2, 600 do
    deep[i] = assert(gui.box())
    assert(deep[i - 1]:add(deep[i]))
end
refused(function() deep[600]:add(deep[1]) end, "parent cycle")
local deep_holder = assert(gui.box())
assert(deep_holder:add(deep[1]))

-- GTK parsing diagnostics are intentionally left to GTK. Both valid and
-- invalid CSS must remain contained; the invalid sheet may write warnings.
assert(gui.setCss([[.real-gtk-probe { padding: 3px; }]]))
assert(root:addClass("real-gtk-probe"))
assert(root:removeClass("real-gtk-probe"))
assert(gui.setCss(".broken { color: ; }"))
assert(gui.setCss(nil))
assert(window:close())

-- Use a separate top-level whose only child is the DrawingArea. The Python
-- harness locates this X11 window and injects two real primary-button clicks.
local click_window = assert(gui.window {
    title = "Babet real GTK click probe",
    width = 260,
    height = 180,
})
local area = assert(gui.drawingArea {width = 240, height = 160})
assert(click_window:add(area))

local draws = 0
local ready_reported = false
assert(area:onDraw(function(ctx, width, height)
    draws = draws + 1
    assert(ctx:setSourceRGB(1, 1, 1))
    assert(ctx:rectangle(0, 0, width, height))
    assert(ctx:fill())
    assert(ctx:setSourceRGB(0.1, 0.4, 0.8))
    assert(ctx:rectangle(10, 10, 80, 40))
    assert(ctx:stroke())
    assert(ctx:setFontSize(14))
    assert(ctx:text(12, 70, "évolution"))
    if not ready_reported then
        ready_reported = true
        io.stdout:write("REAL_GTK_READY\n")
        io.stdout:flush()
    end
end))

local clicks = {}
assert(area:onClick(function(x, y, button, n_press)
    clicks[#clicks + 1] = {x = x, y = y, button = button, n_press = n_press}
    if #clicks >= 2 then
        assert(gui.quit())
    end
end))

assert(click_window:show())
assert(gui.run())
assert(draws >= 1, "real GTK never invoked DrawingArea:onDraw")
assert(#clicks >= 2, "real GTK did not deliver both injected clicks")
assert(clicks[1].button == 1 and clicks[2].button == 1)
assert(clicks[1].n_press == 1, "first click must have n_press=1")
assert(clicks[2].n_press == 2, "second click must have n_press=2")
assert(type(clicks[1].x) == "number" and type(clicks[1].y) == "number")
assert(clicks[1].x >= 0 and clicks[1].y >= 0)
assert(click_window:close())
print("REAL_GTK_CONTRACT_OK")
