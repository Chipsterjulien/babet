local gui = babet.gui
assert(gui.init())
local main = coroutine.running()
local window = assert(gui.window {title = "Entry events"})
local box = assert(gui.box())
assert(window:add(box))
local weak = setmetatable({}, {__mode = "v"})
local count = 0

do
    local disconnected = assert(gui.entry())
    assert(disconnected:onActivate(function() error("DISCONNECTED_HANDLER_RAN") end))
    assert(disconnected:onActivate(nil))
    assert(box:add(disconnected))

    local bad = assert(gui.entry {text = "error"})
    assert(bad:onActivate(function() error("ENTRY_ACTIVATE_ERROR_SENTINEL") end))
    assert(box:add(bad))

    local entry = assert(gui.entry {text = "retained by parent"})
    assert(box:add(entry))
    assert(entry:onActivate(function() error("REPLACED_HANDLER_RAN") end))
    assert(entry:onActivate(function()
        assert(coroutine.running() == main)
        count = count + 1
        assert(entry:getText() == "retained by parent")
        assert(entry:onChanged(function() count = count + 10 end))
        assert(entry:setText("activated"))
        assert(entry:onActivate(nil))
        assert(window:close())
        collectgarbage("collect")
    end))
    weak[1] = entry
end
collectgarbage("collect")
assert(weak[1], "parent lost its Lua child")
assert(window:show())
assert(gui.run())
assert(count == 11, "activate and changed must have separate handlers")
local ok, err = pcall(function() weak[1]:getText() end)
assert(not ok and tostring(err):find("already been destroyed", 1, true), tostring(err))
window, box = nil, nil
collectgarbage("collect")
collectgarbage("collect")
assert(weak[1] == nil, "closed widget callback cycle leaked")
print("ENTRY_EVENTS_OK")
