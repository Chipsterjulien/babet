local gui = assert(babet.gui)
assert(gui.init())

local window = assert(gui.window {title = "Babet real GTK desktop probe", width = 720, height = 420})
assert(window:setIconName("document-edit-symbolic"))
local root = assert(gui.box {orientation = "vertical", spacing = 4})
assert(window:add(root))

local menu_row = assert(gui.box {orientation = "horizontal", spacing = 3})
assert(root:add(menu_row))
local menu = assert(gui.menuButton {label = "Note"})
local menu_popover = assert(gui.popover {hasArrow = false, position = "bottom"})
local menu_content = assert(gui.box {orientation = "vertical"})
assert(menu_content:add(assert(gui.button("Edit"))))
assert(menu_content:add(assert(gui.separator("horizontal"))))
assert(menu_content:add(assert(gui.checkButton {label = "To Do"})))
assert(menu_popover:add(menu_content))
assert(menu:setPopover(menu_popover))
assert(menu_row:add(menu))
assert(menu_row:add(assert(gui.image("document-edit-symbolic"))))

local paned = assert(gui.paned {orientation = "horizontal", position = 170, resizeStart = false})
local side = assert(gui.box {orientation = "vertical"})
assert(side:add(assert(gui.label("Baskets"))))
local canvas = assert(gui.fixed())
assert(canvas:setHExpand(true)); assert(canvas:setVExpand(true))
assert(paned:add(side)); assert(paned:add(canvas)); assert(root:add(paned))

local position_events = 0
assert(paned:onPositionChanged(function(position)
    assert(type(position) == "number" and position >= 0)
    position_events = position_events + 1
end))
assert(paned:setPosition(190))

local note = assert(gui.label("note-handle"))
assert(note:setSizeRequest(130, 32))
assert(note:setCursor("grab"))
assert(note:setTooltipText("Move note"))
assert(note:setHAlign("start")); assert(note:setVAlign("center"))
assert(canvas:put(note, 410, 55))
local text = assert(gui.textView {text = "one\ntwo", editable = true, wrap = "word-char"})
assert(text:setSizeRequest(180, 70))
assert(canvas:put(text, 410, 100))

local context = assert(gui.popover {hasArrow = true, autohide = true, position = "bottom"})
local context_box = assert(gui.box {orientation = "vertical"})
assert(context_box:add(assert(gui.button("Edit"))))
assert(context_box:add(assert(gui.button("Delete"))))
assert(context:add(context_box))
assert(context:attachTo(canvas))
assert(context:setPointingTo(250, 180, 1, 1))

local pointer_press, pointer_release = false, false
assert(canvas:onPointer(function(phase, x, y, button)
    if phase == "press" and button == 1 then
        assert(type(x) == "number" and type(y) == "number")
        pointer_press = true
    elseif phase == "release" and button == 1 then
        assert(pointer_press)
        pointer_release = true
        assert(context:setPointingTo(math.floor(x), math.floor(y), 1, 1))
        -- The XTest harness must not inject Escape until GTK has actually
        -- dispatched the release. Do not open and immediately close an
        -- autohide popover here: GTK can swallow the following key even when
        -- X11 reports the correct focus and no grab. real_gtk_popover.lua
        -- exercises popup/popdown through separate, acknowledged events.
        io.stdout:write("REAL_GTK_DESKTOP_POINTER_OK\n"); io.stdout:flush()
    end
end))

local key_press, key_release = false, false
assert(window:onKey(function(phase, name)
    if name == "Escape" and phase == "press" then
        key_press = true
        assert(pointer_press and pointer_release)
        local w, h = canvas:getSize()
        assert(w > 0 and h > 0)
        local x, y = note:translatePoint(canvas, 0, 0)
        assert(type(x) == "number" and type(y) == "number")
        assert(x >= 0 and y >= 0)
        assert(paned:getPosition() > 0)
        assert(position_events > 0)
        return true
    elseif name == "Escape" and phase == "release" then
        key_release = true
        assert(window:close())
        assert(gui.quit())
    end
    return false
end))

-- Dialog primitives must be real GTK windows but need not be presented here.
local dialog = assert(gui.window {title = "Properties", width = 280, height = 160})
assert(dialog:setTransientFor(window))
assert(dialog:setModal(true))
assert(dialog:close())

assert(window:show())
io.stdout:write("REAL_GTK_DESKTOP_READY\n"); io.stdout:flush()
assert(gui.run())
assert(pointer_press and pointer_release and key_press and key_release)
print("REAL_GTK_DESKTOP_OK")
