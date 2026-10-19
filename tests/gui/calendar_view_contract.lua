-- Native events are supplied by the fake GTK main loop, never by setDate().
local gui = babet.gui
local case = assert(os.getenv("BABET_CALENDAR_CASE"))
assert(gui.init())
local window = assert(gui.window())
local root = assert(gui.box {orientation = "vertical"})
local calendar = assert(gui.calendar {year = 2024, month = 1, day = 31})
local finish = assert(gui.button("finish Calendar scenario"))
assert(window:add(root))
assert(root:add(calendar))
assert(root:add(finish))
local failure, verify
local calls, changes = 0, 0
assert(calendar:onChanged(function() changes = changes + 1 end))

-- Binding callbacks intentionally contain Lua errors. Record unexpected test
-- assertions separately so they cannot silently turn into a passing fixture.
local function checked(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            failure = failure or tostring(err)
            gui.quit()
        end
    end
end
local function date(y, m, d)
    local yy, mm, dd = calendar:getDate()
    assert(yy == y and mm == m and dd == d,
        string.format("expected %04d-%02d-%02d, got %04d-%02d-%02d", y, m, d, yy, mm, dd))
end

if case == "navigation" then
    local expected = {
        {2024, 2, 29}, {2024, 1, 29}, {2025, 1, 29},
        {2024, 1, 29}, {2023, 12, 29}, {2024, 1, 29},
    }
    assert(calendar:onViewChanged(checked(function(...)
        assert(select("#", ...) == 0, "view callback takes no arguments")
        calls = calls + 1
        local wanted = assert(expected[calls], "extra view callback")
        date(table.unpack(wanted))
        assert(changes == 0, "navigation must not synthesize day-selected in this fake")
        assert(calendar:clearMarks())
        assert(calendar:markDay(expected[calls][2]))
        assert(calendar:markDay(31))
        assert(calendar:unmarkDay(31))
    end)))
    -- Populate every bit so the native log also proves clearMarks() cleared
    -- old months; checking only function calls would miss a no-op wrapper.
    for day = 1, 31 do assert(calendar:markDay(day)) end
    verify = function()
        assert(calls == #expected, "not all four native navigation signals reached Lua")
        date(2024, 1, 29)
        local weak = setmetatable({}, {__mode = "v"})
        for _ = 1, 50 do
            do
                local c = assert(gui.calendar())
                assert(c:onViewChanged(function() return c:getDate() end))
                weak[1] = c
            end
            collectgarbage("collect")
            collectgarbage("collect")
            assert(weak[1] == nil, "onViewChanged callback cycle retained its calendar")
        end
    end
elseif case == "replacement" then
    local replacements = 0
    assert(calendar:onViewChanged(checked(function()
        calls = calls + 1
        date(2024, 2, 29)
        assert(calendar:onViewChanged(checked(function()
            replacements = replacements + 1
            date(2024, 3, 29)
            assert(calendar:onViewChanged(nil))
        end)))
    end)))
    verify = function()
        assert(calls == 1 and replacements == 1, "callback replacement/removal failed")
        date(2024, 4, 29) -- third native event still occurs after removal
    end
elseif case == "error" or case == "yield" then
    local recovered = 0
    assert(calendar:onViewChanged(function()
        calls = calls + 1
        assert(calendar:onViewChanged(checked(function()
            recovered = recovered + 1
            date(2024, 3, 29)
        end)))
        if case == "error" then error("CALENDAR_VIEW_ERROR_SENTINEL") end
        coroutine.yield("Calendar yield must not cross GTK")
    end))
    verify = function()
        assert(calls == 1 and recovered == 1, "event loop did not recover after callback failure")
    end
elseif case == "reentrant" then
    assert(calendar:onViewChanged(checked(function()
        calls = calls + 1
        if calls == 1 then
            date(2024, 2, 29)
            assert(calendar:setDate(2030, 12, 15))
            date(2030, 12, 15)
            assert(calls == 1, "setDate recursively emitted onViewChanged")
            assert(changes == 1, "setDate lost its synchronous onChanged")
        else
            assert(calls == 2, "extra view callback")
            date(2031, 1, 15)
        end
    end)))
    -- Even changing the month programmatically must not emit onViewChanged.
    assert(calendar:setDate(2023, 12, 31))
    assert(calendar:setDate(2024, 1, 31))
    assert(calls == 0, "setDate emitted onViewChanged")
    changes = 0
    verify = function() assert(calls == 2 and changes == 1) end
elseif case == "close" then
    assert(calendar:onViewChanged(checked(function()
        calls = calls + 1
        date(2024, 2, 29)
        assert(window:close())
        collectgarbage("collect")
    end)))
    verify = function() assert(calls == 1, "view callback did not close its window") end
else
    error("unknown Calendar case: " .. case)
end

assert(finish:onClick(checked(function()
    verify()
    assert(window:close())
end)))
assert(window:show())
assert(gui.run())
assert(not failure, failure)
if case == "close" then
    verify()
    local ok, err = pcall(function() calendar:getDate() end)
    assert(not ok and tostring(err):find("already been destroyed", 1, true), tostring(err))
end
print("GUI_CALENDAR_VIEW_OK:" .. case)
