local gui = babet.gui
local function rejects(fn, text)
    local ok, err = pcall(fn)
    assert(not ok and tostring(err):find(text, 1, true), tostring(err))
end
local function pair(...)
    assert(select('#', ...) == 2 and select(1, ...) == true and select(2, ...) == nil)
end
rejects(function() gui.drawingArea() end, "init")
assert(gui.init())
local worker = assert(babet.workers.spawn([[
    local ok, err = pcall(babet.gui.drawingArea)
    assert(not ok and tostring(err):find("main thread", 1, true), tostring(err))
    return "DRAWING_WORKER_REJECTED"
]]))
local joined, worker_result = worker:join(5)
assert(joined and worker_result == "DRAWING_WORKER_REJECTED", tostring(worker_result))
for _, options in ipairs{1, false, "table"} do
    rejects(function() gui.drawingArea(options) end, "options table")
end
rejects(function() gui.drawingArea({}, {}) end, "options table")
for _, field in ipairs{"width", "height"} do
    for _, value in ipairs{0, -1, 2147483648, 1.5, "12", true, math.huge, 0/0} do
        rejects(function() gui.drawingArea({[field] = value}) end, "gui.drawingArea")
    end
end
local defaults = assert(gui.drawingArea(setmetatable({}, {
    __index = function() error("OPTIONS_METAMETHOD_RAN") end
})))
local default_nil = assert(gui.drawingArea(nil))
defaults, default_nil = nil, nil
collectgarbage("collect")
local window = assert(gui.window())
local column = assert(gui.box())
local area = assert(gui.drawingArea {width = 200, height = 100})
local entry = assert(gui.entry {text = "readable during drawing"})
local spin = assert(gui.spinButton {min = 0, max = 200, value = 91.4, digits = 1})
local calendar = assert(gui.calendar {year = 2026, month = 10, day = 7})
assert(window:add(column))
assert(column:add(area))
assert(column:add(entry))
assert(column:add(spin))
assert(column:add(calendar))
rejects(function() area:onDraw() end, "function or nil")
rejects(function() area:onDraw(true) end, "function or nil")
rejects(function() area:onDraw(nil, nil) end, "function or nil")
rejects(function() area:queueDraw(true) end, "no arguments")
rejects(function() entry:onDraw(function() end) end, "drawingArea")
rejects(function() area:getText() end, "entry")
rejects(function() area:setText("x") end, "only label")
local main = coroutine.running()
local saved, called = nil, 0
pair(area:onDraw(function(ctx, width, height)
    assert(coroutine.running() == main and width == 200 and height == 100)
    assert(select('#', ctx, width, height) == 3)
    called = called + 1
    saved = ctx
    assert(entry:getText() == "readable during drawing")
    assert(math.abs(spin:getValue() - 91.4) < 1e-9)
    local year, month, day = calendar:getDate()
    assert(year == 2026 and month == 10 and day == 7)
    for _, f in ipairs{
        function() gui.window() end, function() gui.drawingArea() end,
        function() gui.scrolledWindow() end, function() gui.spinButton() end,
        function() gui.calendar() end,
        function() gui.init() end, function() gui.available() end,
        function() gui.run() end, function() window:close() end,
        function() window:show() end, function() column:add(entry) end,
        function() column:remove(entry) end, function() column:clear() end,
        function() entry:setText("forbidden") end,
        function() entry:setEditable(false) end,
        function() entry:setPlaceholder("forbidden") end,
        function() entry:onChanged(nil) end,
        function() entry:setMargins(1) end, function() entry:setHExpand(true) end,
        function() entry:setVExpand(true) end, function() entry:setVisible(true) end,
        function() entry:setSensitive(true) end,
        function() area:onDraw(nil) end, function() area:queueDraw() end,
    } do rejects(f, "forbidden during onDraw") end

    pair(ctx:newPath())
    pair(ctx:setSourceRGB(1, 1, 1))
    pair(ctx:rectangle(0, 0, width, height))
    pair(ctx:fill())
    pair(ctx:setSourceRGBA(1, 0, 0, 1))
    pair(ctx:rectangle(10, 10, 30, 20))
    pair(ctx:fill())
    pair(ctx:setSourceRGB(0, 0, 1))
    pair(ctx:setLineWidth(4))
    pair(ctx:moveTo(50, 10))
    pair(ctx:lineTo(100, 10))
    pair(ctx:stroke())
    pair(ctx:newPath())
    pair(ctx:setSourceRGB(0, 1, 0))
    pair(ctx:arc(80, 60, 10, 0, 2 * math.pi))
    pair(ctx:fill())
    pair(ctx:moveTo(120, 15))
    pair(ctx:lineTo(130, 15))
    pair(ctx:lineTo(125, 25))
    pair(ctx:closePath())
    pair(ctx:stroke())
    pair(ctx:setSourceRGB(0, 0, 0))
    pair(ctx:setFontSize(12))
    pair(ctx:text(4, 90, "Été 91.4 kg"))
    pair(ctx:text(190, 90, ""))

    for _, value in ipairs{true, "1", {}, math.huge, -math.huge, 0/0} do
        rejects(function() ctx:moveTo(value, 0) end, "finite number")
        rejects(function() ctx:setLineWidth(value) end, "finite number")
        rejects(function() ctx:setSourceRGB(0, 0, value) end, "finite number")
    end
    rejects(function() ctx:setLineWidth(0) end, "positive")
    rejects(function() ctx:setFontSize(-1) end, "positive")
    rejects(function() ctx:arc(0, 0, -1, 0, 1) end, "non-negative")
    rejects(function() ctx:setSourceRGBA(0, 0, 0, 2) end, "[0, 1]")
    rejects(function() ctx:setSourceRGB(-0.1, 0, 0) end, "[0, 1]")
    rejects(function() ctx:text(0, 0, 123) end, "string")
    rejects(function() ctx:text(0, 0, "a\0b") end, "NUL")
    for _, text in ipairs{"\255", "\128", "\192\128", "\224\128\128",
                          "\237\160\128", "\244\144\128\128", "\226\130"} do
        rejects(function() ctx:text(0, 0, text) end, "UTF-8")
    end
    for _, method in ipairs{"newPath", "closePath", "stroke", "fill"} do
        rejects(function() ctx[method](ctx, 1) end, "number of arguments")
    end
    rejects(function() ctx:lineTo(1) end, "number of arguments")
    rejects(function() ctx:rectangle(1, 2, 3) end, "number of arguments")
    rejects(function() ctx:arc(1, 2, 3, 4) end, "number of arguments")
    rejects(function() ctx:text(1, 2) end, "number of arguments")
    rejects(function() ctx.setFontSize({}, 2) end, "BabetGuiDrawContext")
    -- Caught validation errors must not poison Cairo. A main-thread coroutine
    -- can use the current borrowed context synchronously, but cannot retain it.
    local co = coroutine.create(function() pair(ctx:newPath()) end)
    assert(coroutine.resume(co))
    collectgarbage("collect")
    pair(gui.quit())
end))
assert(called == 0, "onDraw registration must not draw synchronously")
pair(area:queueDraw())
assert(called == 0, "queueDraw must be asynchronous")
assert(window:show())
assert(gui.run())
assert(called == 1 and saved)
rejects(function() saved:moveTo(1, 2) end, "only valid during")
rejects(function() saved:stroke() end, "only valid during")
rejects(function() saved:text(1, 2, "expired") end, "only valid during")
assert(window:close())
rejects(function() area:queueDraw() end, "already been destroyed")
window, column, area, entry, spin, calendar, saved = nil, nil, nil, nil, nil, nil, nil
collectgarbage("collect")

-- More than MAX_WIDGETS creations: native draw destroy-notify and Lua cycles
-- must release all references, including widgets that were never parented.
local weak = setmetatable({}, {__mode = "v"})
for i = 1, 150 do
    do
        local item = assert(gui.drawingArea())
        assert(item:onDraw(function() return item end))
        weak[1] = item
    end
    collectgarbage("collect")
    collectgarbage("collect")
    assert(weak[1] == nil, "drawing callback cycle leaked")
end
print("DRAWING_CONTRACT_OK")
