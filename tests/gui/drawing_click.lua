local gui = babet.gui
assert(gui.init())

local w = assert(gui.window {title = "Drawing click", width = 320, height = 220})
local b = assert(gui.box {orientation = "vertical", spacing = 2})
local a = assert(gui.drawingArea {width = 300, height = 180})
assert(w:add(b)); assert(b:add(a))

local calls = 0
local first_x, first_y, first_button

assert(a:onClick(function(x, y, button)
    calls = calls + 1
    assert(type(x) == "number" and x == 42.5)
    assert(type(y) == "number" and y == 73.25)
    assert(math.type(button) == "integer" and button == 1)
    first_x, first_y, first_button = x, y, button

    -- Event callbacks are allowed to mutate widgets and request a redraw.
    assert(a:queueDraw())

    -- Self-removal must be safe and must not affect onDraw.
    assert(a:onClick(nil))
    assert(gui.quit())
end))

assert(a:onDraw(function(ctx)
    assert(ctx:newPath())
end))

assert(w:show())
assert(gui.run())
assert(calls == 1)
assert(first_x == 42.5 and first_y == 73.25 and first_button == 1)
assert(w:close())

-- Wrong widget keeps the historical button diagnostic.
local entry = assert(gui.entry())
local ok, err = pcall(function() entry:onClick(function() end) end)
assert(not ok and tostring(err):find("expected a button handle", 1, true), tostring(err))

print("DRAWING_CLICK_OK")
