local gui = babet.gui
local mode = arg[1] or "normal"
assert(gui.init())
local window = assert(gui.window {title = "Babet real GTK DND probe", width = 460, height = 170})
local root = assert(gui.box {orientation = "horizontal", spacing = 20})
local source = assert(gui.label("Drag me"))
local outer = assert(gui.box())
local target = assert(gui.label("Drop here"))
assert(source:setSizeRequest(180, 120))
assert(target:setSizeRequest(180, 120))
assert(source:setHExpand(true)); assert(outer:setHExpand(true))
assert(target:setHExpand(true)); assert(target:setVExpand(true))
assert(outer:add(target)); assert(root:add(source)); assert(root:add(outer))
assert(window:add(root))
if mode == "copy-action" then
    assert(source:setDragActions({"copy", "move"}))
    assert(target:setDropActions({"copy", "move"}))
    assert(outer:setDropActions({"copy", "move"}))
end
assert(source:setDragData("real-row-7"))
local drag_end_action, drag_end_delete
if mode == "copy-action" then
    assert(source:onDragState(function(phase, detail, action)
        if phase == "end" then drag_end_action, drag_end_delete = action, detail end
    end))
end
local saw_enter, saw_motion, saw_drop, closed = false, false, false, false
local inner_calls, inner_drops, outer_drops = 0, 0, 0
local parent_enters, parent_motions = 0, 0
local expect_outer = mode == "disabled-child" or mode == "self-disable-enter"
local function receive(is_inner, phase, payload, x, y, action)
    if is_inner then inner_calls = inner_calls + 1 end
    if phase == "enter" or phase == "motion" then
        if not is_inner then
            if phase == "enter" then parent_enters = parent_enters + 1
            else parent_motions = parent_motions + 1 end
        end
        if phase == "enter" then saw_enter = true else saw_motion = true end
        if payload ~= nil then assert(payload == "real-row-7") end
        assert(type(x) == "number" and type(y) == "number")
        if is_inner and phase == "enter" then
            if mode == "self-disable-enter" then assert(target:onDrop(nil)) end
            if mode == "clear-source" then assert(source:setDragData(nil)) end
        end
        if mode == "copy-action" then
            assert(action == "move" or action == "copy")
            return "copy"
        end
        if is_inner and mode == "nested-hover-false" then return false end
    elseif phase == "drop" then
        assert(payload == "real-row-7")
        assert(type(x) == "number" and type(y) == "number")
        if is_inner then inner_drops = inner_drops + 1 else outer_drops = outer_drops + 1 end
        saw_drop = true
        if mode == "remove-source" then
            assert(root:remove(source)); source = nil
            collectgarbage("collect"); collectgarbage("collect")
        end
        if mode == "close-drop" then
            closed = true
            assert(window:close())
        else
            if mode == "self-disable-drop" then assert(target:onDrop(nil)) end
            assert(gui.quit())
            if mode == "nested-drop-false" then return false end
        end
    end
end
assert(outer:onDrop(function(...) return receive(false, ...) end))
local function receive_inner(...) return receive(true, ...) end
assert(target:onDrop(receive_inner))
if mode == "disabled-child" or mode == "reenabled-child" then
    assert(target:onDrop(nil))
    if mode == "reenabled-child" then assert(target:onDrop(receive_inner)) end
end
assert(window:show())
io.stdout:write("REAL_GTK_DND_READY\n"); io.stdout:flush()
assert(gui.run())
assert(saw_enter and saw_motion and saw_drop)
assert(inner_drops == (expect_outer and 0 or 1))
assert(outer_drops == (expect_outer and 1 or 0))
if mode == "disabled-child" then assert(inner_calls == 0) end
if mode == "nested-hover-false" or mode == "nested-drop-false" then
    assert(parent_enters > 0 and parent_motions > 0)
    assert(inner_drops == 1 and outer_drops == 0)
end
if mode == "copy-action" then
    assert(drag_end_action == "copy", tostring(drag_end_action))
    assert(drag_end_delete == false)
end
if not closed then assert(window:close()) end
print("REAL_GTK_DND_OK:" .. mode)
