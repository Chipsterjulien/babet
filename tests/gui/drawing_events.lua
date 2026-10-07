local gui = babet.gui
assert(gui.init())
local function expired(ctx)
    local ok, err = pcall(function() ctx:stroke() end)
    assert(not ok and tostring(err):find("only valid during", 1, true), tostring(err))
end
local window = assert(gui.window())
local box = assert(gui.box())
local area = assert(gui.drawingArea())
local change = assert(gui.button("Change"))
assert(window:add(box))
assert(box:add(area))
assert(box:add(change))
local saved, count = nil, 0
assert(area:onDraw(function() error("REPLACED_DRAW_RAN") end))
assert(area:onDraw(function(ctx)
    saved = ctx
    count = count + 1
    error("DRAW_ERROR_SENTINEL")
end))
assert(change:onClick(function()
    assert(count == 1)
    expired(saved)
    assert(area:onDraw(function(ctx)
        expired(saved)
        saved = ctx
        count = count + 1
        assert(ctx:moveTo(0, 0))
        assert(ctx:lineTo(20, 20))
        assert(ctx:stroke())
        assert(gui.quit())
    end))
    assert(area:queueDraw())
    assert(count == 1)
end))
assert(window:show())
assert(gui.run())
assert(count == 2)
expired(saved)

-- Removal is explicit nil. Fake GTK still renders but must not call Lua.
assert(area:onDraw(function() error("REMOVED_DRAW_RAN") end))
assert(area:onDraw(nil))
local stop = assert(gui.button("Stop"))
assert(box:add(stop))
assert(stop:onClick(function() assert(gui.quit()) end))
assert(gui.run())
assert(count == 2)
assert(window:close())
window, box, area, change, stop, saved = nil, nil, nil, nil, nil, nil
collectgarbage("collect")

-- Errors and attempts to yield never escape GTK; the following button event
-- remains usable and a saved context is invalidated in both cases.
for _, mode in ipairs{"yield", "object"} do
    local w = assert(gui.window())
    local b = assert(gui.box())
    local a = assert(gui.drawingArea())
    local done = assert(gui.button("Done"))
    assert(w:add(b)); assert(b:add(a)); assert(b:add(done))
    local captured
    assert(a:onDraw(function(ctx)
        captured = ctx
        if mode == "yield" then coroutine.yield() else error({}) end
    end))
    assert(done:onClick(function() expired(captured); assert(gui.quit()) end))
    assert(w:show()); assert(gui.run()); assert(w:close())
    expired(captured)
end
collectgarbage("collect")

-- Explicit finalization and an automatic GC during drawing may not destroy
-- GTK objects until the native drawing stage has fully returned.
local w = assert(gui.window())
local b = assert(gui.box())
local a = assert(gui.drawingArea())
assert(w:add(b)); assert(b:add(a))
local garbage = assert(gui.entry {text = "collected during draw"})
local weak = setmetatable({a}, {__mode = "v"})
assert(a:onDraw(function(ctx)
    garbage = nil
    collectgarbage("collect")
    local finalize = debug.getmetatable(w).__gc
    finalize(w)
    finalize(weak[1])
    assert(ctx:rectangle(0, 0, 10, 10)); assert(ctx:fill())
    assert(gui.quit())
end))
a = nil
collectgarbage("collect")
assert(weak[1], "parent failed to root drawing child")
assert(w:show()); assert(gui.run())
local ok, err = pcall(function() w:show() end)
assert(not ok and tostring(err):find("already been destroyed", 1, true), tostring(err))
w, b = nil, nil
collectgarbage("collect"); collectgarbage("collect")
assert(weak[1] == nil)
print("DRAWING_EVENTS_OK")
