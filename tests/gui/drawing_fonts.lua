-- Exercise real text again after the isolated fake GTK fixture has released
-- Cairo and Fontconfig caches. No runtime cleanup hook is involved.
local gui = babet.gui
assert(gui.init())
local total = 0
for generation = 1, 3 do
    local window = assert(gui.window())
    local area = assert(gui.drawingArea {width = 200, height = 100})
    assert(window:add(area))
    assert(area:onDraw(function(ctx, width, height)
        assert(ctx:setSourceRGB(1, 1, 1))
        assert(ctx:rectangle(0, 0, width, height))
        assert(ctx:fill())
        assert(ctx:setSourceRGB(0, 0, 0))
        assert(ctx:setFontSize(14))
        assert(ctx:text(8, 30, "Été - 91.4 kg"))
        total = total + 1
        assert(gui.quit())
    end))
    assert(window:show())
    for redraw = 1, 4 do
        assert(area:queueDraw())
        assert(gui.run())
        assert(total == (generation - 1) * 4 + redraw)
    end
    assert(window:close())
end
collectgarbage("collect")
print("DRAWING_FONTS_OK")
