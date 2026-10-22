local gui = assert(babet.gui)
assert(gui.init())

local window = assert(gui.window {title = "Babet real GTK popover probe", width = 320, height = 240})
local root = assert(gui.box {orientation = "vertical"})
assert(window:add(root))
local ready_area = assert(gui.drawingArea {width = 200, height = 20})
assert(root:add(ready_area))
local opener = assert(gui.button("Open context menu"))
assert(opener:setVExpand(true))
assert(root:add(opener))

local popover = assert(gui.popover {autohide = true, position = "bottom"})
local content = assert(gui.box {orientation = "vertical"})
local popup_area = assert(gui.drawingArea {width = 160, height = 20})
local closer = assert(gui.button("Close context menu"))
assert(content:add(popup_area)); assert(content:add(closer))
assert(popover:add(content)); assert(popover:attachTo(opener))

local ready, opened, drawn, closed = false, false, false, false
local function marker(text)
    io.stdout:write(text .. "\n"); io.stdout:flush()
end
assert(ready_area:onDraw(function(_, width, height)
    assert(width > 0 and height > 0)
    if not ready then
        ready = true
        marker("REAL_GTK_POPOVER_READY")
    end
end))
assert(opener:onClick(function()
    assert(ready and not opened)
    opened = true
    assert(popover:popup())
    assert(closer:grabFocus())
end))
assert(popup_area:onDraw(function(_, width, height)
    assert(opened and width > 0 and height > 0)
    if not drawn then
        drawn = true
        marker("REAL_GTK_POPOVER_DRAWN")
    end
end))
assert(closer:onClick(function()
    -- The driver sends Space only after the popup's first real draw. Closing
    -- therefore happens in another event, never in the opening callback.
    assert(drawn and not closed)
    assert(popover:popdown())
    closed = true
    assert(gui.quit())
end))

assert(window:show())
assert(gui.run())
assert(ready and opened and drawn and closed)
assert(window:close())
collectgarbage("collect")
print("REAL_GTK_POPOVER_OK")
