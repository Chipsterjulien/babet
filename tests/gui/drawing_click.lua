local gui = babet.gui
assert(gui.init())

local w = assert(gui.window {title = "Drawing click", width = 320, height = 220})
local b = assert(gui.box {orientation = "vertical", spacing = 2})
local a = assert(gui.drawingArea {width = 300, height = 180})
assert(w:add(b)); assert(b:add(a))

local calls = 0
local first_x, first_y, first_button, first_n_press
local second_n_press

assert(a:onClick(function(x, y, button, n_press)
    calls = calls + 1
    assert(type(x) == "number" and x == 42.5)
    assert(type(y) == "number" and y == 73.25)
    assert(math.type(button) == "integer" and button == 1)
    assert(math.type(n_press) == "integer")
    if calls == 1 then
        assert(n_press == 1)
        first_x, first_y, first_button, first_n_press = x, y, button, n_press
        -- Event callbacks are allowed to mutate widgets and request a redraw.
        assert(a:queueDraw())
    elseif calls == 2 then
        assert(n_press == 2)
        second_n_press = n_press
        -- Self-removal must be safe and must not affect onDraw.
        assert(a:onClick(nil))
        assert(gui.quit())
    else
        error("unexpected extra click callback")
    end
end))

assert(a:onDraw(function(ctx)
    assert(ctx:newPath())
end))

assert(w:show())
assert(gui.run())
assert(calls == 2)
assert(first_x == 42.5 and first_y == 73.25 and first_button == 1 and first_n_press == 1)
assert(second_n_press == 2)
assert(w:close())

-- Wrong widget keeps the historical button diagnostic.
local entry = assert(gui.entry())
local ok, err = pcall(function() entry:onClick(function() end) end)
assert(not ok and tostring(err):find("expected a button handle", 1, true), tostring(err))

print("DRAWING_CLICK_OK")
