-- Real GTK4 regression: the onDrag handle moves with its parent GtkFixed note.
-- Surface-coordinate offsets must continue tracking the XTest pointer.
local gui = babet.gui
assert(gui.init())
local w = assert(gui.window {title = "Babet real GTK drag probe", width = 480, height = 330})
local canvas = assert(gui.fixed())
canvas:setSizeRequest(480, 330)
assert(w:add(canvas))
local block = assert(gui.box {orientation = "vertical"})
block:setSizeRequest(180, 60)
local title = assert(gui.label("Drag handle"))
title:setSizeRequest(180, 60)
assert(block:add(title))
local x, y = 20, 20
assert(canvas:put(block, x, y))
local started, updates, ended = false, 0, false
local drag_failure = nil
assert(title:onDrag(function(phase, dx, dy)
    if phase == "begin" then
        started = true
    elseif phase == "update" or phase == "end" then
        if phase == "update" then updates = updates + 1 end
        x, y = 20 + dx, 20 + dy
        local call_ok, moved, move_error = pcall(canvas.move, canvas, block, x, y)
        if not call_ok then
            drag_failure = "canvas:move failed: " .. tostring(moved)
            assert(w:close())
            return
        end
        if not moved then
            drag_failure = "canvas:move returned failure: " .. tostring(move_error)
            assert(w:close())
            return
        end
        if phase == "end" then
            ended = true
            if not started or updates < 1 then
                drag_failure = "drag ended without begin/update events"
            elseif math.abs(x - 120) >= 7 or math.abs(y - 70) >= 7 then
                drag_failure = ("drag ended at %.2f %.2f (expected 120,70)"):format(x, y)
            else
                print("REAL_GTK_DRAG_OK", x, y)
                io.stdout:flush()
            end
            assert(w:close())
        end
    end
end))
local ready = assert(gui.drawingArea {width = 1, height = 1})
assert(canvas:put(ready, 0, 0))
local fired = false
assert(ready:onDraw(function()
    if not fired then
        fired = true
        print("REAL_GTK_DRAG_READY")
        io.stdout:flush()
    end
end))
w:show()
assert(gui.run())
assert(ended or drag_failure, "drag ended without an end event")
assert(not drag_failure, drag_failure)
