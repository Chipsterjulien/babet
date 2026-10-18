local gui = babet.gui
assert(gui.init())
local window = assert(gui.window {title = "Babet real GTK progress probe", width = 300, height = 130})
local bar = assert(gui.progressBar())
assert(bar:setSizeRequest(260, 110))
assert(window:add(bar))
local steps = 0
assert(bar:onClick(function(x, y, button, npress)
    assert(button == 1 and npress >= 1)
    assert(x >= 0 and y >= 0)
    steps = steps + 1
    assert(bar:setFraction(math.min(1, steps / 4)))
    if steps == 4 then assert(gui.quit()) end
end))
assert(window:show())
io.stdout:write("REAL_GTK_PROGRESS_READY\n")
io.stdout:flush()
assert(gui.run())
assert(steps == 4 and bar:getFraction() == 1)
assert(window:close())
print("REAL_GTK_PROGRESS_OK")
