local gui = assert(babet.gui)
local mode = assert(arg[1])
assert(gui.init())
assert(gui.setCss([[.icon-source { background-color: #ff0000; color: #ffffff; }
                   .icon-preview { background-color: #00ff00; color: #000000; }
                   .icon-target { background-color: #0000ff; color: #ffffff; }]]))
local window = assert(gui.window {title="Babet real GTK DND probe", width=460, height=240})
local root = assert(gui.box {orientation="vertical"})
local row = assert(gui.box {orientation="horizontal", spacing=20})
local source, target = assert(gui.label("visible-source")), assert(gui.label("target"))
assert(source:setSizeRequest(180,170)); assert(target:setSizeRequest(180,170))
assert(source:setHExpand(true)); assert(target:setHExpand(true))
assert(source:addClass("icon-source")); assert(target:addClass("icon-target"))
assert(row:add(source)); assert(row:add(target)); assert(root:add(row)); assert(window:add(root))
local preview = assert(gui.label("custom-preview"))
assert(preview:addClass("icon-preview")); assert(preview:setSizeRequest(180,50))
-- Configured before show: selection must be refreshed at drag-begin, not
-- permanently resolved here. The hidden ancestor case also needs get_mapped,
-- not just the preview's own visible property.
assert(source:setDragIcon(preview)); assert(source:setDragData("icon-row"))
local holder = assert(gui.box {orientation="vertical"})
if mode ~= "unparented" then assert(holder:add(preview)); assert(root:add(holder)) end
assert(window:show())
if mode == "hidden" or mode == "detached" or mode == "destroyed" then
    -- Also cover an initially mapped preview that becomes unusable after
    -- installation. A construction-time fallback alone would miss this case.
    assert(source:setDragIcon(preview))
end
if mode == "hidden" then assert(holder:setVisible(false))
elseif mode == "detached" then assert(holder:remove(preview))
elseif mode == "destroyed" then
    assert(holder:remove(preview))
    local other = assert(gui.window {title="temporary preview owner"})
    assert(other:add(preview)); assert(other:close())
elseif mode == "reset" then assert(source:setDragIcon(nil))
else assert(mode == "mapped" or mode == "unparented") end
-- No onDragState callback: icon refresh must not depend on one being present.
local dropped = false
assert(target:onDrop(function(phase, payload)
    if phase == "drop" then
        assert(payload == "icon-row"); dropped = true; assert(gui.quit())
    end
    return true
end))
io.stdout:write("REAL_GTK_DND_READY\n"); io.stdout:flush()
assert(gui.run()); assert(dropped); assert(window:close())
print("GUI_DND_ICON_OK:" .. mode)
