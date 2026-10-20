local gui = babet.gui
assert(gui.init())

local mode = assert(arg[1], "missing DND rejection mode")
assert(mode == "drop-false" or mode == "enter-error", mode)

local function pair(ok, err)
    assert(ok == true and err == nil, tostring(err))
end

local window = assert(gui.window {title = "native dnd reject", width = 360, height = 140})
local root = assert(gui.box {orientation = "horizontal", spacing = 8})
local source = assert(gui.label("source"))
local target = assert(gui.label("target"))
pair(source:setDragData("reject-row"))
pair(root:add(source))
pair(root:add(target))
pair(window:add(root))

local phases = {}
pair(target:onDrop(function(phase, payload)
    phases[#phases + 1] = phase
    if payload ~= nil then assert(payload == "reject-row", tostring(payload)) end
    if phase == "drop" then assert(gui.quit()) end
    if mode == "drop-false" and phase == "drop" then
        return false
    end
    if mode == "enter-error" and phase == "enter" then
        error("DND_ERROR_SENTINEL")
    end
    -- Hover feedback is not a permanent GTK rejection. Always check the
    -- final drop too; a later motion/leave may follow the failed enter.
    if mode == "enter-error" and phase == "drop" then return false end
    if phase == "leave" then assert(gui.quit()) end
    return true
end))

pair(window:show())
assert(gui.run())
assert(table.concat(phases, ",") == "enter,motion,drop", table.concat(phases, ","))
pair(window:close())
print("GUI_NATIVE_DND_REJECT_OK:" .. mode)
