local gui = assert(babet.gui)
assert(gui.init())

local win = assert(gui.window {title = "Desktop primitives", width = 900, height = 600})
assert(win:setTitle("Desktop primitives updated"))
assert(win:setIconName("document-edit-symbolic"))

local root = assert(gui.box {orientation = "vertical", spacing = 4})
assert(win:add(root))

-- A menu bar can be assembled from real GtkMenuButton + GtkPopover widgets.
local menu_row = assert(gui.box {orientation = "horizontal", spacing = 4})
assert(root:add(menu_row))
local menu = assert(gui.menuButton {label = "Note"})
local menu_popover = assert(gui.popover {hasArrow = false, autohide = true, position = "bottom"})
local menu_content = assert(gui.box {orientation = "vertical", spacing = 2})
assert(menu_content:add(assert(gui.button("Edit"))))
assert(menu_content:add(assert(gui.separator("horizontal"))))
assert(menu_content:add(assert(gui.checkButton {label = "To Do", active = false})))
assert(menu_popover:add(menu_content))
assert(menu:setPopover(menu_popover))
assert(menu:popup())
assert(menu:popdown())
assert(menu_row:add(menu))

local icon = assert(gui.image("document-edit-symbolic"))
assert(icon:setIconName("edit-copy-symbolic"))
assert(menu_row:add(icon))
local icon_button = assert(gui.button(""))
assert(icon_button:setIconName("edit-delete-symbolic"))
assert(menu_row:add(icon_button))
assert(icon_button:grabFocus())
assert(icon_button:hasFocus() == true)

assert(root:add(assert(gui.separator("horizontal"))))

local paned = assert(gui.paned {
    orientation = "horizontal", position = 180,
    resizeStart = false, resizeEnd = true,
    shrinkStart = true, shrinkEnd = true, wideHandle = false,
})
assert(paned:getPosition() == 180)
local positions = {}
assert(paned:onPositionChanged(function(position)
    positions[#positions + 1] = position
end))
assert(paned:setPosition(210))
assert(paned:getPosition() == 210)
assert(positions[#positions] == 210)

local left = assert(gui.box {orientation = "vertical", spacing = 2})
assert(left:add(assert(gui.label("Baskets"))))
local canvas = assert(gui.fixed())
assert(canvas:setHExpand(true))
assert(canvas:setVExpand(true))
assert(paned:add(left))
assert(paned:add(canvas))
assert(root:add(paned))

-- Paned keeps a dense two-child Lua contract even if the first pane is
-- removed: the surviving end child is promoted to start, so add() can safely
-- fill the end slot again. This catches a subtle native/logical slot drift.
local slot_probe = assert(gui.paned {orientation = "horizontal"})
local slot_a = assert(gui.label("slot-a"))
local slot_b = assert(gui.label("slot-b"))
local slot_c = assert(gui.label("slot-c"))
assert(slot_probe:add(slot_a)); assert(slot_probe:add(slot_b))
assert(slot_probe:remove(slot_a))
assert(slot_probe:add(slot_c))
assert(slot_probe:clear())

local handle = assert(gui.label("drag-handle"))
assert(handle:setSizeRequest(120, 30))
assert(handle:setHAlign("start"))
assert(handle:setVAlign("center"))
assert(handle:setCursor("grab"))
assert(handle:setTooltipText("Move note"))
assert(canvas:put(handle, 20, 30))
local width, height = handle:getSize()
assert(width == 120 and height == 30, string.format("unexpected fake size %s x %s", width, height))
local tx, ty = handle:translatePoint(canvas, 1, 2)
assert(tx == 21 and ty == 32, string.format("unexpected translation %s,%s", tostring(tx), tostring(ty)))
local picked = assert(canvas:pick(21, 31))
assert(picked == handle, "pick() must return the nearest Babet child handle")
assert(canvas:pick(5, 5) == canvas, "blank fixed-space pick must resolve to the canvas")

local text = assert(gui.textView {text = "line 1\nline 2", editable = true, wrap = "word-char"})
assert(text:setWrapMode("word"))
assert(text:setSizeRequest(220, 70))
assert(canvas:put(text, 170, 40))

-- Right-click/context menus need a popover attached directly to a widget.
local context = assert(gui.popover {hasArrow = true, autohide = true, position = "bottom"})
local context_box = assert(gui.box {orientation = "vertical", spacing = 1})
assert(context_box:add(assert(gui.button("Edit"))))
assert(context_box:add(assert(gui.button("Delete"))))
assert(context:add(context_box))
assert(context:attachTo(canvas))
assert(context:setPointingTo(20, 30, 1, 1))
assert(context:popup())
assert(context:popdown())
assert(context:attachTo(nil))
assert(context:attachTo(canvas))

local pointer = {}
assert(handle:onPointer(function(phase, x, y, button, n_press, modifiers)
    pointer[#pointer + 1] = {phase, x, y, button, n_press, modifiers}
end))

local keys = {}
assert(win:onKey(function(phase, name, keyval, keycode, modifiers)
    keys[#keys + 1] = {phase, name, keyval, keycode, modifiers}
    return phase == "press" and name == "Escape"
end))

local close_requests = 0
assert(win:onCloseRequest(function()
    close_requests = close_requests + 1
    return true
end))

-- Rich native DND: several actions, a custom drag icon, action feedback and
-- begin/end/cancel notification without coupling the model to GTK widgets.
local preview = assert(gui.label("drag-preview"))
assert(menu_row:add(preview))
assert(handle:setDragActions({"copy", "move", "link"}))
assert(handle:setDragIcon(preview))
assert(handle:setDragData("desktop-row"))
local drag_states = {}
assert(handle:onDragState(function(phase, detail, action)
    drag_states[#drag_states + 1] = {phase, detail, action}
end))

local target = assert(gui.label("drop-target"))
assert(target:setSizeRequest(160, 40))
assert(canvas:put(target, 420, 80))
assert(target:setDropActions({"copy", "move", "link"}))
local drops = {}
assert(target:onDrop(function(phase, payload, x, y, action)
    drops[#drops + 1] = {phase, payload, x, y, action}
    -- The fake integration injects Ctrl. Prefer COPY so the source receives
    -- the exact action ultimately selected by GTK.
    if phase == "enter" or phase == "motion" then return "copy" end
    return true
end))

-- Modal/transient windows are needed for basket/note properties.
local dialog = assert(gui.window {title = "Properties", width = 320, height = 180})
assert(dialog:setTransientFor(win))
assert(dialog:setModal(true))
assert(dialog:close())

local finish = assert(gui.button("Finish desktop contract"))
assert(root:add(finish))
assert(finish:onClick(function()
    local seen = {}
    for _, event in ipairs(pointer) do
        seen[event[1]] = true
        if event[1] == "press" or event[1] == "release" then
            assert(event[4] == 3 and event[5] == 1)
            assert((event[6] & gui.MOD_CONTROL) ~= 0)
        elseif event[1] == "leave" then
            assert(event[2] == nil and event[3] == nil)
        end
    end
    for _, phase in ipairs({"press", "release", "enter", "motion", "leave"}) do
        assert(seen[phase], "missing pointer phase " .. phase)
    end
    assert(#keys == 2)
    assert(keys[1][1] == "press" and keys[1][2] == "Escape")
    assert((keys[1][5] & gui.MOD_CONTROL) ~= 0)
    assert(keys[2][1] == "release")
    assert(close_requests == 1)

    local drop_seen = {}
    for _, event in ipairs(drops) do
        drop_seen[event[1]] = true
        if event[1] ~= "leave" then
            assert(event[5] == "copy", tostring(event[5]))
        end
    end
    assert(drop_seen.enter and drop_seen.motion and drop_seen.drop)
    assert(#drag_states >= 2)
    assert(drag_states[1][1] == "begin")
    assert(drag_states[#drag_states][1] == "end")
    assert(drag_states[#drag_states][2] == false) -- COPY does not delete source data
    assert(drag_states[#drag_states][3] == "copy")

    assert(win:onCloseRequest(nil))
    assert(win:close())
    assert(gui.quit())
end))

assert(win:show())
assert(gui.run())
print("GUI_DESKTOP_UI_CONTRACT_OK")
