-- Fake GTK emits begin/update/end: callbacks receive the documented coordinates.
local gui = babet.gui
assert(gui.init())
local w = assert(gui.window())
local canvas = assert(gui.fixed())
local row = assert(gui.box())
local header = assert(gui.label("Drag handle"))
assert(row:add(header))
assert(canvas:put(row, 20, 40))
assert(w:add(canvas))
local sequence, lastx, lasty = {}, 20, 40
local updates = 0
assert(header:onDrag(function(phase, x, y)
    sequence[#sequence+1] = phase
    if phase == "begin" then
        assert(x == 4 and y == 9)
    else
        if phase == "update" then updates = updates + 1 end
        local expected_x = updates == 1 and 25.5 or 50.5
        local expected_y = updates == 1 and -12 or -20
        assert(x == expected_x and y == expected_y,
               ("drag %s: %.1f %.1f, expected %.1f %.1f"):format(
                   phase, x, y, expected_x, expected_y))
        assert(canvas:move(row, lastx + x, lasty + y))
        if phase == "end" then assert(w:close()) end
    end
end))
w:show()
assert(gui.run())
assert(table.concat(sequence, ",") == "begin,update,update,end")
print("GUI_FREE_LAYOUT_DRAG_OK")
