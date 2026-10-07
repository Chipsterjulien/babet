local gui = babet.gui

local function rejects(fn, text)
    local ok, err = pcall(fn)
    assert(not ok and tostring(err):find(text, 1, true), tostring(err))
end

local function pair(ok, err)
    assert(ok == true and err == nil, tostring(err))
end

rejects(function() gui.scrolledWindow() end, "init() first")
rejects(function() gui.spinButton() end, "init() first")
rejects(function() gui.calendar() end, "init() first")
assert(gui.init())

-- Box removal/clearing: removed children remain valid and can be reparented.
local box = assert(gui.box())
local other = assert(gui.box())
local a = assert(gui.label("a"))
local b = assert(gui.label("b"))
pair(box:add(a))
pair(box:add(b))
rejects(function() other:remove(a) end, "does not belong")
pair(box:remove(a))
pair(a:setText("a-after-remove"))
pair(other:add(a))
pair(other:remove(a))
pair(box:clear())
pair(b:setText("b-after-clear"))
pair(other:add(b))
pair(other:clear())
rejects(function() box:remove(a) end, "does not belong")
rejects(function() gui.label("x"):clear() end, "box or scrolledWindow")
rejects(function() gui.window():clear() end, "box or scrolledWindow")
rejects(function() box:remove() end, "one child")
rejects(function() box:clear(1) end, "no arguments")

-- ScrolledWindow has one logical child, supports remove/clear and preserves it.
local scroll = assert(gui.scrolledWindow())
local row = assert(gui.box())
pair(scroll:add(row))
rejects(function() scroll:add(assert(gui.label("second"))) end, "already has a child")
pair(scroll:remove(row))
pair(row:setMargins(2))
pair(scroll:add(row))
pair(scroll:clear())
pair(row:setHExpand(true))
pair(scroll:add(row))
pair(scroll:remove(row))
rejects(function() gui.scrolledWindow(1) end, "expects no arguments")

-- Clearing must release the Lua root and the native parent reference.
local weak = setmetatable({}, {__mode = "v"})
for i = 1, 100 do
    do
        local child = assert(gui.label("temporary"))
        weak[1] = child
        pair(box:add(child))
        pair(box:clear())
    end
    collectgarbage("collect")
    collectgarbage("collect")
    assert(weak[1] == nil, "Box:clear kept a child alive")
end
for i = 1, 100 do
    do
        local child = assert(gui.label("temporary"))
        weak[1] = child
        pair(scroll:add(child))
        pair(scroll:clear())
    end
    collectgarbage("collect")
    collectgarbage("collect")
    assert(weak[1] == nil, "ScrolledWindow:clear kept a child alive")
end

-- SpinButton defaults, options, strict validation and synchronous onChanged.
local spin = assert(gui.spinButton())
assert(spin:getValue() == 0 and select("#", spin:getValue()) == 1)
local configured = assert(gui.spinButton {
    min = 30, max = 200, step = 0.1, value = 91.4, digits = 1,
})
assert(math.abs(configured:getValue() - 91.4) < 1e-9)
assert(math.abs(assert(gui.spinButton(nil)):getValue()) < 1e-9)
local range_default = assert(gui.spinButton {min = 30, max = 250, step = 0.1, digits = 1})
assert(math.abs(range_default:getValue() - 30) < 1e-9)
local raw_spin = assert(gui.spinButton(setmetatable({}, {
    __index = function() error("SpinButton options must use raw access") end,
})))
assert(raw_spin:getValue() == 0)
for _, value in ipairs {false, 42, "x", function() end} do
    rejects(function() gui.spinButton(value) end, "options table")
end
rejects(function() gui.spinButton({}, {}) end, "options table")
rejects(function() gui.spinButton {min = 10, max = 1} end, "less than or equal")
rejects(function() gui.spinButton {step = 0} end, "step must be positive")
rejects(function() gui.spinButton {value = 101} end, "within min and max")
rejects(function() gui.spinButton {digits = -1} end, "digits")
rejects(function() gui.spinButton {digits = 21} end, "digits")
rejects(function() gui.spinButton {digits = 1.5} end, "integer")
rejects(function() gui.spinButton {value = math.huge} end, "finite")
rejects(function() gui.spinButton {step = 0/0} end, "finite")
rejects(function() spin:getValue(1) end, "no arguments")
rejects(function() spin:setValue() end, "one number")
rejects(function() spin:setValue("1") end, "number")
rejects(function() spin:setValue(math.huge) end, "finite")
rejects(function() a:getValue() end, "spinButton")
pair(spin:setValue(1000))
assert(spin:getValue() == 100)
pair(spin:setValue(-1000))
assert(spin:getValue() == 0)

local spin_changes = 0
pair(spin:onChanged(function()
    spin_changes = spin_changes + 1
    assert(spin:getValue() == 12.5)
end))
pair(spin:setValue(12.5))
assert(spin_changes == 1)
pair(spin:onChanged(function()
    spin_changes = spin_changes + 10
    pair(spin:onChanged(nil))
    pair(spin:setValue(13.5))
end))
pair(spin:setValue(13))
assert(spin_changes == 11 and spin:getValue() == 13.5)
pair(spin:setValue(14))
assert(spin_changes == 11)
pair(spin:onChanged(function() error("SPIN_CHANGED_ERROR_SENTINEL") end))
pair(spin:setValue(15))
pair(spin:onChanged(function() coroutine.yield("spin yield must not cross GTK") end))
pair(spin:setValue(16))
pair(spin:onChanged(nil))

local caller = coroutine.create(function()
    local current = coroutine.running()
    local observed
    pair(spin:onChanged(function() observed = coroutine.running() end))
    pair(spin:setValue(17))
    assert(observed == current, "SpinButton changed must use synchronous caller")
end)
assert(coroutine.resume(caller))
assert(coroutine.status(caller) == "dead")
pair(spin:onChanged(nil))

-- The native object/state must stay pinned if a synchronous callback closes parent.
local spin_window = assert(gui.window())
local spin_child = assert(gui.spinButton {min = 0, max = 10})
pair(spin_window:add(spin_child))
pair(spin_child:onChanged(function() pair(spin_window:close()) end))
pair(spin_child:setValue(1))
rejects(function() spin_child:getValue() end, "already been destroyed")

-- Calendar supports past dates, strict Gregorian validation and synchronous changes.
local calendar = assert(gui.calendar {year = 2024, month = 2, day = 29})
local y, m, d = calendar:getDate()
assert(y == 2024 and m == 2 and d == 29 and select("#", calendar:getDate()) == 3)
assert(gui.calendar(nil))
assert(gui.calendar(setmetatable({}, {
    __index = function() error("Calendar options must use raw access") end,
})))
for _, value in ipairs {false, 42, "x", function() end} do
    rejects(function() gui.calendar(value) end, "options table")
end
rejects(function() gui.calendar({}, {}) end, "options table")
rejects(function() gui.calendar {year = 2024} end, "provided together")
rejects(function() gui.calendar {year = 2024, month = 2} end, "provided together")
rejects(function() gui.calendar {year = 2023, month = 2, day = 29} end, "invalid Gregorian date")
rejects(function() gui.calendar {year = 0, month = 1, day = 1} end, "invalid Gregorian date")
rejects(function() gui.calendar {year = 2024, month = 13, day = 1} end, "invalid Gregorian date")
rejects(function() gui.calendar {year = 2024.0, month = 1, day = 1} end, "integer")
rejects(function() calendar:getDate(1) end, "no arguments")
rejects(function() calendar:setDate(2024, 2) end, "year, month and day")
rejects(function() calendar:setDate(2023, 2, 29) end, "invalid Gregorian date")
rejects(function() calendar:setDate("2024", 1, 1) end, "integer")
rejects(function() a:getDate() end, "calendar")

local date_changes = 0
pair(calendar:onChanged(function()
    date_changes = date_changes + 1
    local yy, mm, dd = calendar:getDate()
    assert(yy == 1999 and mm == 12 and dd == 31)
end))
pair(calendar:setDate(1999, 12, 31))
assert(date_changes == 1)
pair(calendar:onChanged(function()
    date_changes = date_changes + 10
    pair(calendar:onChanged(nil))
    pair(calendar:setDate(2000, 1, 2))
end))
pair(calendar:setDate(2000, 1, 1))
assert(date_changes == 11)
y, m, d = calendar:getDate()
assert(y == 2000 and m == 1 and d == 2)
pair(calendar:onChanged(function() error("CALENDAR_CHANGED_ERROR_SENTINEL") end))
pair(calendar:setDate(2001, 1, 1))
pair(calendar:onChanged(nil))

local calendar_window = assert(gui.window())
local calendar_child = assert(gui.calendar {year = 2026, month = 10, day = 7})
pair(calendar_window:add(calendar_child))
pair(calendar_child:onChanged(function() pair(calendar_window:close()) end))
pair(calendar_child:setDate(2026, 10, 8))
rejects(function() calendar_child:getDate() end, "already been destroyed")

-- Common properties apply to every live widget and keep strict Lua types.
local common = assert(gui.label("common"))
pair(common:setMargins(4))
pair(common:setMargins(1, 2, 3, 4))
pair(common:setHExpand(true))
pair(common:setHExpand(false))
pair(common:setVExpand(true))
pair(common:setVisible(false))
pair(common:setVisible(true))
pair(common:setSensitive(false))
pair(common:setSensitive(true))
rejects(function() common:setMargins() end, "one margin")
rejects(function() common:setMargins(1, 2) end, "one margin")
rejects(function() common:setMargins(-1) end, "out of range")
rejects(function() common:setMargins(1.5) end, "integers")
rejects(function() common:setHExpand(1) end, "boolean")
rejects(function() common:setVExpand(nil) end, "boolean")
rejects(function() common:setVisible("yes") end, "boolean")
rejects(function() common:setSensitive(1) end, "boolean")

-- Callback cycles on the new signal-bearing widgets must remain collectable.
for i = 1, 100 do
    do
        local s = assert(gui.spinButton())
        pair(s:onChanged(function() return s:getValue() end))
        weak[1] = s
        local c = assert(gui.calendar {year = 2026, month = 10, day = 7})
        pair(c:onChanged(function() return c:getDate() end))
        weak[2] = c
    end
    collectgarbage("collect")
    collectgarbage("collect")
    assert(weak[1] == nil and weak[2] == nil, "new widget callback cycle leaked")
end

print("GUI_WIDGETS_CONTRACT_OK")
