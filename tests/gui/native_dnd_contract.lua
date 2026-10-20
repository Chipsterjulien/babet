local gui = babet.gui
assert(gui.init())

local function pair(ok, err)
    assert(ok == true and err == nil, tostring(err))
end

local function rejects(fn, needle)
    local ok, err = pcall(fn)
    assert(not ok and tostring(err):find(needle, 1, true), tostring(err))
end

local window = assert(gui.window {title = "native dnd", width = 420, height = 180})
local root = assert(gui.box {orientation = "horizontal", spacing = 12})
local handle = assert(gui.label("drag-handle"))
local target = assert(gui.box {orientation = "vertical", spacing = 4})
local target_text = assert(gui.label("drop-target"))
pair(target:add(target_text))
pair(root:add(handle))
pair(root:add(target))
pair(window:add(root))

rejects(function() gui.button("bad"):setDragData("x") end, "non-interactive drag handle")
rejects(function() handle:setDragData("a\0b") end, "cannot contain NUL")
rejects(function() handle:setDragData(string.char(0xff)) end, "valid UTF-8")
rejects(function() target:onDrop(42) end, "function or nil")
rejects(function() window:onDrop(function() end) end, "windows cannot be drop targets")

pair(handle:setDragData("initial-row"))
pair(handle:setDragData("row-42"))
pair(handle:setText("visible-handle")) -- live icon follows the handle, not the ID
local phases = {}
pair(target:onDrop(function(phase, payload, x, y)
    phases[#phases + 1] = phase
    if phase == "enter" then
        assert(payload == "row-42" and x == 8 and y == 12)
    elseif phase == "motion" then
        assert(payload == "row-42" and x == 9 and y == 24)
    elseif phase == "drop" then
        assert(payload == "row-42" and x == 9 and y == 24)
        assert(gui.quit())
    elseif phase == "leave" then
        assert(payload == nil and x == nil and y == nil)
        assert(gui.quit())
    else
        error("unexpected DND phase: " .. tostring(phase))
    end
end))

pair(window:show())
assert(gui.run())
assert(table.concat(phases, ",") == "enter,motion,drop")
pair(target:onDrop(nil))
pair(handle:setDragData(nil))
pair(window:close())
print("GUI_NATIVE_DND_CONTRACT_OK")
