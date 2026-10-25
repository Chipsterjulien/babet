-- Target of tools/test_gui_real_dnd_external.py: a drag from another process.
io.stdout:setvbuf("no")
local gui = babet.gui
assert(gui.init())
local mode = arg[1]
local mixed = mode == "mixed-files" or mode == "mixed-link"
local window = assert(gui.window{title = "Babet external drop target", width = 300, height = 200})
local outer = assert(gui.box{orientation = "vertical"})
local target = assert(gui.label("drop"))
assert(target:setSizeRequest(300, 200))
assert(outer:add(target))
assert(window:add(outer))

local function show(payload)
    if type(payload) == "table" then return table.concat(payload, "|") end
    return tostring(payload)
end

local nested = mode == "nested" or mode == "nested-enter"
assert(target:setDropTypes(mixed and {"text", "files"} or nested and {"files"} or {"text"}))
assert(target:setDropActions(mixed and "copy" or {"copy", "move"}))
if nested then
    -- "nested": the child refuses hover and its parent accepts COPY. GTK still
    -- delivers the drop to the child: it must see the parent's action.
    -- "nested-enter": released right after entering. GTK asks the parent
    -- first and keeps its MOVE, even though the child prefers COPY.
    assert(outer:setDropTypes({"files"}))
    assert(outer:setDropActions({"copy", "move"}))
    assert(outer:onDrop(function(phase)
        if phase == "drop" then print("EXTERNAL_PARENT_DROP"); gui.quit(); return false end
        if phase ~= "leave" then return mode == "nested-enter" and "move" or "copy" end
    end))
end
assert(target:onDrop(function(phase, payload, x, y, action, kind)
    if phase == "enter" or phase == "motion" then
        if mode == "nested" then return false end
        if mode == "hover-copy" or mode == "nested-enter" then return "copy" end
        return true
    end
    if phase == "drop" then
        print(("EXTERNAL_DROP kind=%s action=%s payload=%s"):format(
            tostring(kind), tostring(action), show(payload)))
        gui.quit()
        -- Returning the reported action proves that it is the negotiated one.
        return action or false
    end
end))
assert(window:show())
print("EXTERNAL_TARGET_READY")
assert(gui.run())
print("EXTERNAL_TARGET_DONE")
