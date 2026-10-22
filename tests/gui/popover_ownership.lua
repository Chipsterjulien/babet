local gui = babet.gui
local mode = assert(arg[1])
assert(gui.init())
local function cycle(fn)
    local ok, err = pcall(fn)
    assert(not ok and tostring(err):find("cycle", 1, true), tostring(err))
end

if mode == "cycles" then
    -- Each direction matters: menu ownership is stored outside the child array.
    local p, m = assert(gui.popover()), assert(gui.menuButton {label="menu"})
    assert(p:add(m))
    cycle(function() m:setPopover(p) end)
    assert(p:remove(m))
    assert(m:setPopover(p))
    cycle(function() p:add(m) end)
    assert(m:setPopover(nil))
    assert(p:add(m)); assert(p:remove(m))

    local b = assert(gui.box())
    assert(p:attachTo(b))
    cycle(function() p:add(b) end)
    assert(p:attachTo(nil))
    assert(p:add(b))
    cycle(function() p:attachTo(b) end)
    assert(p:remove(b))

    -- A context edge followed by a menu edge must also be traversed.
    local context, menu_pop = assert(gui.popover()), assert(gui.popover())
    assert(context:attachTo(b)); assert(context:add(m)); assert(m:setPopover(menu_pop))
    cycle(function() menu_pop:add(b) end)
    assert(m:setPopover(nil)); assert(context:remove(m)); assert(context:attachTo(nil))

    -- Fixed and collapsed Expander paths use the same logical cycle guard.
    local fixed = assert(gui.fixed())
    assert(p:attachTo(fixed))
    local inner = assert(gui.fixed())
    assert(p:add(inner))
    cycle(function() inner:put(fixed, 0, 0) end)
    assert(p:remove(inner)); assert(p:attachTo(nil))
    assert(inner:put(fixed, 0, 0)); assert(inner:remove(fixed))
    local expander = assert(gui.expander {label="collapsed", expanded=false})
    assert(expander:add(m)); assert(m:setPopover(p))
    cycle(function() p:add(expander) end)
    assert(m:setPopover(nil)); assert(expander:remove(m))
    -- A custom drag icon is a lifetime reference, not a parenting edge.
    local handle = assert(gui.label("handle"))
    assert(handle:setDragIcon(b)); assert(b:add(handle)); assert(b:remove(handle))
    assert(handle:setDragIcon(nil))
elseif mode == "lifetime" then
    for _, make in ipairs({function() return gui.label("parent") end,
                          function() return gui.button("parent") end,
                          function() return gui.box() end}) do
        local w, parent = assert(gui.window()), assert(make())
        assert(w:add(parent))
        local first, second = assert(gui.popover()), assert(gui.popover())
        assert(first:add(assert(gui.label("first"))))
        assert(second:add(assert(gui.label("second"))))
        assert(first:attachTo(parent)); assert(second:attachTo(parent))
        assert(w:close())
        local w2, replacement = assert(gui.window()), assert(gui.label("replacement"))
        assert(w2:add(replacement))
        assert(first:attachTo(replacement)); assert(second:attachTo(replacement))
        assert(w2:close())
        assert(first:attachTo(nil)); assert(second:attachTo(nil))
    end
else error("unknown popover test mode") end
collectgarbage("collect"); collectgarbage("collect")
print("GUI_POPOVER_OWNERSHIP_OK:" .. mode)
