-- Native GtkBox reorder and GtkProgressBar pointer events. The fake GTK
-- insists that each reorder occurs without any unparenting.
local gui = babet.gui
assert(gui.init())
local function pair(ok, err) assert(ok == true and err == nil, tostring(err)) end
local function rejects(fn, expected)
    local ok, err = pcall(fn)
    assert(not ok and type(err) == "string" and err:find(expected, 1, true), tostring(err))
end

local list = assert(gui.box {spacing = 4})
local a, b, c, d = gui.label("row-a"), gui.label("row-b"),
                      gui.label("row-c"), gui.label("row-d")
for _, row in ipairs {a, b, c, d} do pair(list:add(row)) end
-- Move last after first, then first to the end, then current middle to start.
pair(list:reorder(d, a))
pair(list:reorder(a, c))
pair(list:reorder(c, nil))
pair(list:reorder(c, c)) -- member/self no-op, never call GTK
rejects(function() list:reorder(gui.label("outside"), nil) end, "does not belong")
rejects(function() list:reorder(b, gui.label("outside")) end, "does not belong")
rejects(function() gui.label("not a box"):reorder(a, nil) end, "expected")
rejects(function() list:reorder(b, 4) end, "got number")
local unsupported_click = gui.label("unsupported-click")
rejects(function() unsupported_click:onClick(function() end) end,
        "expected a button, drawingArea or progressBar")
rejects(function() unsupported_click:onClick(nil) end,
        "expected a button, drawingArea or progressBar")
-- A removed row is still a live Lua handle, and can be attached again.
pair(list:remove(d))
rejects(function() list:reorder(d, nil) end, "does not belong")
pair(list:add(d))
pair(list:reorder(d, nil))

local bar = assert(gui.progressBar())
local caption = assert(gui.label("One chapter"))
local line = assert(gui.box {orientation = "horizontal", spacing = 8})
pair(line:add(bar))
pair(line:add(caption))
pair(bar:setShowText(true))
pair(bar:setText("0 %"))
local clicks = 0
pair(bar:onClick(function(x, y, button, npress)
    assert(type(x) == "number" and type(y) == "number")
    assert(button == 1 and npress >= 1)
    clicks = clicks + 1
    local fraction = clicks / 4
    pair(bar:setFraction(fraction))
    pair(bar:setText(tostring(clicks * 25) .. " %"))
    if fraction >= 1 then
        pair(caption:addClass("completed"))
        pair(gui.quit())
    end
end))
rejects(function() bar:onClick(2) end, "function or nil")
local w = assert(gui.window {title = "native widget contract"})
local root = assert(gui.box())
pair(root:add(list))
pair(root:add(line))
pair(w:add(root))
pair(w:show())
pair(gui.run())
assert(clicks == 4 and bar:getFraction() == 1)
pair(bar:onClick(nil))
-- clear() walks Babet's logical Lua child table. The fake GTK logs each
-- removed row, so the harness can prove that Lua and GTK kept the same order.
pair(list:clear())
pair(w:close())
print("GUI_NATIVE_LIST_CONTRACT_OK")
