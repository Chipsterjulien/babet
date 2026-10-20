local gui = babet.gui
local mode = assert(arg[1])
assert(gui.init())
local window = assert(gui.window())
local root = assert(gui.box {orientation = "horizontal"})
local source = assert(gui.label("source"))
local outer = assert(gui.box())
local inner = assert(gui.label("dnd-hit"))
assert(outer:add(inner)); assert(root:add(source)); assert(root:add(outer))
assert(window:add(root))
local original = string.rep("row-before-", 20)
assert(source:setDragData(original))
local closed, outer_drops, inner_drops, replaced = false, 0, 0, 0
local phases, outer_phases = {}, {}
local function check_payload(phase, payload)
    if phase == "leave" then assert(payload == nil)
    elseif mode == "delayed" and phase ~= "drop" then assert(payload == nil)
    else assert(payload == original, tostring(payload)) end
end
assert(outer:onDrop(function(phase, payload)
    outer_phases[#outer_phases + 1] = phase
    check_payload(phase, payload)
    if phase == "drop" then outer_drops = outer_drops + 1; assert(gui.quit()) end
    if phase == "leave" then assert(gui.quit()) end
end))
local function replacement(phase, payload)
    replaced = replaced + 1
    check_payload(phase, payload)
    if phase == "drop" then inner_drops = inner_drops + 1; assert(gui.quit()) end
end
local function callback(phase, payload)
    phases[#phases + 1] = phase
    check_payload(phase, payload)
    if phase == "drop" then inner_drops = inner_drops + 1; assert(gui.quit()) end
    if phase == "leave" then assert(gui.quit()) end
    if mode == "close-" .. phase then
        closed = true
        assert(window:close())
    elseif mode == "clear-source" and phase == "enter" then
        assert(source:setDragData(nil))
    elseif mode == "replace-source" and phase == "enter" then
        assert(source:setDragData("row-after"))
    elseif mode == "self-disable-" .. phase then
        assert(inner:onDrop(nil))
    elseif mode == "toggle-enter" and phase == "enter" then
        assert(inner:onDrop(nil))
        assert(inner:onDrop(replacement))
    elseif mode == "replace-callback" and phase == "enter" then
        assert(inner:onDrop(replacement))
    elseif mode == "hover-recover" and phase == "enter" then
        return false
    elseif (mode == "hover-false" or mode == "hover-false-alone") and (phase == "motion" or phase == "drop") then
        return false
    elseif mode == "hover-yield" and phase == "enter" then
        coroutine.yield()
    end
end
assert(inner:onDrop(callback))
if mode == "hover-false-alone" then assert(outer:onDrop(nil)) end
if mode == "disabled" or mode == "reenabled" then
    assert(inner:onDrop(nil))
    if mode == "reenabled" then assert(inner:onDrop(callback)) end
end
assert(window:show()); assert(gui.run())
if mode == "disabled" then
    assert(#phases == 0 and outer_drops == 1 and inner_drops == 0)
elseif mode == "self-disable-enter" or mode == "toggle-enter" then
    assert(table.concat(phases, ",") == "enter")
    assert(outer_drops == 1 and inner_drops == 0)
    if mode == "toggle-enter" then
        -- A new gesture must work after disable/re-enable in the old enter.
        assert(gui.run())
        assert(outer_drops == 1 and inner_drops == 1)
    end
elseif mode == "close-enter" then
    assert(table.concat(phases, ",") == "enter" and inner_drops == 0)
elseif mode == "close-drop" or mode == "self-disable-drop" then
    assert(table.concat(phases, ",") == "enter,motion,drop")
    assert(inner_drops == 1 and outer_drops == 0)
elseif mode == "replace-callback" then
    assert(table.concat(phases, ",") == "enter" and replaced == 2)
    assert(inner_drops == 1 and outer_drops == 0)
elseif mode == "cancel" or mode == "close-leave" or mode == "hover-false-alone" then
    assert(table.concat(phases, ",") == "enter,motion,leave")
    assert(inner_drops == 0 and outer_drops == 0)
else
    assert(table.concat(phases, ",") == "enter,motion,drop")
    assert(inner_drops == 1 and outer_drops == 0)
end
if mode == "reenabled" or mode == "hover-false" then
    -- Parent hover does not imply parent drop; no leave follows the child's drop.
    assert(table.concat(outer_phases, ",") == "enter,motion")
end
if not closed then assert(window:close()) end

-- A callback capturing its own handle must still be collectable.
local weak = setmetatable({}, {__mode = "v"})
for i = 1, 100 do
    do
        local handle = assert(gui.label("cycle"))
        assert(handle:setDragData("cycle-id"))
        assert(handle:onDrop(function() return handle ~= nil end))
        weak[1] = handle
    end
    collectgarbage("collect"); collectgarbage("collect")
    assert(weak[1] == nil, "DND callback retained its Lua handle")
end
print("GUI_NATIVE_DND_LIFECYCLE_OK:" .. mode)
