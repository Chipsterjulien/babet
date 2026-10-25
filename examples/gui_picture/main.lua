-- Generic image viewer. GTK 4.10 for the chooser, GTK 4.6 for file textures.
local gui = babet.gui
assert(gui.init())
local window = assert(gui.window {title = "Babet — image viewer", width = 640, height = 480})
local box = assert(gui.box {orientation = "vertical", spacing = 8})
local open = assert(gui.button("Open image…"))
local status = assert(gui.label("Choose a PNG or JPEG image"))
local picture = assert(gui.picture())
assert(picture:setAlternativeText("Selected image"))
assert(picture:setHExpand(true)); assert(picture:setVExpand(true))
assert(box:setMargin(12))
assert(box:add(open)); assert(box:add(picture)); assert(box:add(status))
assert(window:add(box))
assert(open:onClick(function()
    assert(open:setSensitive(false))
    local started, err = gui.openFile({
        title = "Open image", parent = window,
        filters = {{name = "Images", patterns = {"*.png", "*.jpg", "*.jpeg"}, mimeTypes = {"image/*"}}},
    }, function(path, error_message)
        assert(open:setSensitive(true))
        if error_message then
            assert(status:setText(error_message))
        elseif path then
            local ok, load_error = picture:setFile(path)
            if ok then
                local width, height = picture:getIntrinsicSize()
                assert(status:setText(string.format("%s — %d × %d", path, width, height)))
            else
                assert(status:setText(load_error))
            end
        end
    end)
    if not started then
        assert(open:setSensitive(true)); assert(status:setText(err))
    end
end))
assert(window:show()); assert(gui.run())
