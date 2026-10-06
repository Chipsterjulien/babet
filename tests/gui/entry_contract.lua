local gui = babet.gui
local function rejects(fn, text)
    local ok, err = pcall(fn)
    assert(not ok and tostring(err):find(text, 1, true), tostring(err))
end
rejects(function() gui.entry() end, "init() first")
assert(gui.init())

-- Defaults, raw options, exact types and UTF-8/long text snapshots.
local entry = assert(gui.entry())
assert(entry:getText() == "")
assert(assert(gui.entry(nil)):getText() == "")
assert(assert(gui.entry(setmetatable({}, {
    __index = function() error("options must use raw access") end,
}))):getText() == "")
local configured = assert(gui.entry {
    text = "été — 東京", placeholder = "Saisir…", editable = false,
})
assert(configured:getText() == "été — 東京")
assert(configured:setText("programmatic edit while read-only"))
assert(configured:getText() == "programmatic edit while read-only")
assert(configured:setEditable(true))
assert(configured:setPlaceholder("Nouveau repère"))
assert(configured:setPlaceholder(""))
local long = ("é😀"):rep(2048)
assert(entry:setText(long))
local snapshot = entry:getText()
assert(snapshot == long and select("#", entry:getText()) == 1)
assert(entry:setText(""))
assert(snapshot == long and entry:getText() == "")

for _, value in ipairs {false, 42, "x", function() end} do
    rejects(function() gui.entry(value) end, "optional options table")
end
rejects(function() gui.entry({}, {}) end, "optional options table")
for _, name in ipairs {"text", "placeholder"} do
    rejects(function() gui.entry({[name] = 42}) end, "expected a string")
    rejects(function() gui.entry({[name] = "a\0b"}) end, "embedded NUL")
end
rejects(function() gui.entry {editable = 1} end, "boolean")
rejects(function() entry:getText(1) end, "no arguments")
rejects(function() entry:setText() end, "one string")
rejects(function() entry:setText(1) end, "expected a string")
rejects(function() entry:setText("a\0b") end, "embedded NUL")
rejects(function() entry:setPlaceholder(1) end, "expected a string")
rejects(function() entry:setPlaceholder("a\0b") end, "embedded NUL")
rejects(function() entry:setPlaceholder() end, "one string")
rejects(function() entry:setEditable(1) end, "boolean")
rejects(function() entry:setEditable(true, false) end, "boolean")
for _, method in ipairs {"onChanged", "onActivate"} do
    rejects(function() entry[method](entry) end, "function or nil")
    rejects(function() entry[method](entry, false) end, "function or nil")
    rejects(function() entry[method](entry, nil, nil) end, "function or nil")
end
local label = assert(gui.label("label"))
rejects(function() label:getText() end, "expected an entry handle")
rejects(function() label:setPlaceholder("x") end, "expected an entry handle")
rejects(function() label:setEditable(true) end, "expected an entry handle")
rejects(function() label:onChanged(function() end) end, "expected an entry handle")
rejects(function() label:onActivate(nil) end, "expected an entry handle")
rejects(function() entry:onClick(function() end) end, "expected a button handle")

-- Synchronous notification, replacement, disconnect, reentry and errors.
local changes = 0
assert(entry:onChanged(function()
    changes = changes + 1
    assert(entry:getText() == "first")
end))
assert(entry:setText("first"))
assert(changes == 1)
assert(entry:onChanged(function()
    changes = changes + 10
    assert(entry:onChanged(nil))
    assert(entry:setText("nested without handler"))
end))
assert(entry:setText("replacement"))
assert(changes == 11 and entry:getText() == "nested without handler")
assert(entry:setText("disconnected"))
assert(changes == 11)
assert(entry:onChanged(function()
    assert(entry:onChanged(function() changes = changes + 100 end))
    assert(entry:setText("nested replacement"))
end))
assert(entry:setText("outer"))
assert(changes == 111)
assert(entry:onChanged(function() error("ENTRY_CHANGED_ERROR_SENTINEL") end))
assert(entry:setText("error is contained"))
assert(entry:onChanged(function() coroutine.yield("must not escape GTK") end))
assert(entry:setText("yield is contained"))
assert(entry:onChanged(nil))

local caller = coroutine.create(function()
    local current = coroutine.running()
    local observed
    assert(entry:onChanged(function() observed = coroutine.running() end))
    assert(entry:setText("from coroutine"))
    assert(observed == current, "changed must use the synchronous caller")
end)
assert(coroutine.resume(caller))
assert(coroutine.status(caller) == "dead")
assert(entry:onChanged(nil))

local worker = assert(babet.workers.spawn([[
    local ok, err = pcall(babet.gui.entry)
    assert(not ok and tostring(err):find("main thread", 1, true), tostring(err))
    return "ENTRY_WORKER_REJECTED"
]]))
local joined, worker_result = worker:join(5)
assert(joined and worker_result == "ENTRY_WORKER_REJECTED", tostring(worker_result))

-- Pin both native and logical state while a setter is inside GTK.
local win = assert(gui.window())
local child = assert(gui.entry())
assert(win:add(child))
assert(child:onChanged(function() assert(win:close()) end))
assert(child:setText("close parent during notification"))
rejects(function() child:getText() end, "already been destroyed")
local finalized = assert(gui.entry())
assert(finalized:onChanged(function()
    debug.getmetatable(finalized).__gc(finalized)
    collectgarbage("collect")
end))
assert(finalized:setText("finalize during notification"))
rejects(function() finalized:setText("dead") end, "already been destroyed")

-- A callback cycle must not root an otherwise unreachable widget forever.
-- More than the fixture's live-widget capacity also exposes native leaks.
local weak = setmetatable({}, {__mode = "v"})
for i = 1, 100 do
    do
        local e = assert(gui.entry())
        assert(e:onChanged(function() return e:getText() end))
        assert(e:onActivate(function() return e:getText() end))
        weak[1] = e
        local b = assert(gui.button("cycle"))
        assert(b:onClick(function() return b:setText("captured") end))
        weak[2] = b
    end
    collectgarbage("collect")
    collectgarbage("collect")
    assert(weak[1] == nil and weak[2] == nil, "self-capturing widget leaked")
end
print("ENTRY_CONTRACT_OK")
