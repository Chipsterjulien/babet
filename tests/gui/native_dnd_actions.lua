local gui = babet.gui
local mode = assert(arg[1])
assert(gui.init())
local expected = ({["copy-at-drop"]="move", ["move-at-drop"]="copy",
                  ["drop-false"]="move", ["drop-error"]="move", ["reject-then-move"]="move",
                  copy="copy", move="move", link="link",
                  ["copy-only"]="copy", ["link-only"]="link"})[mode]
assert(expected, mode)
local rejected = mode == "copy-at-drop" or mode == "move-at-drop" or mode == "drop-false" or mode == "drop-error"
local final = mode == "copy-at-drop" and "copy" or mode == "move-at-drop" and "move" or expected
local window = assert(gui.window {title="Babet real GTK DND probe", width=460, height=170})
local root = assert(gui.box {orientation="horizontal", spacing=20})
local source, target = assert(gui.label("source")), assert(gui.label("target"))
assert(source:setSizeRequest(180,120)); assert(target:setSizeRequest(180,120))
assert(source:setHExpand(true)); assert(target:setHExpand(true))
assert(root:add(source)); assert(root:add(target)); assert(window:add(root))
assert(source:setDragActions(mode:find("only",1,true) and expected or {"copy","move","link"}))
assert(target:setDropActions({"copy","move","link"}))
assert(source:setDragData("action-row"))
local dropped, cancelled, ended, deleted, end_action = false, false, false, nil, nil
local end_results = {}
assert(source:onDragState(function(phase, detail, action)
    if phase == "cancel" then cancelled = true end
    if phase == "end" then
        ended, deleted, end_action = true, detail, action
        end_results[#end_results + 1] = detail
        if mode == "reject-then-move" and #end_results == 1 then
            assert(detail == false, "refused first transfer deleted the source")
            cancelled = false
            io.stdout:write("REAL_GTK_DND_AGAIN\n"); io.stdout:flush()
        else
            assert(gui.quit())
        end
    end
end))
assert(target:onDrop(function(phase, payload, x, y, action)
    if phase == "enter" or phase == "motion" then
        if mode:find("only",1,true) then return true end
        return expected
    elseif phase == "drop" then
        assert(payload == "action-row" and action == expected, tostring(action))
        dropped = true
        if mode == "drop-false" or (mode == "reject-then-move" and #end_results == 0) then return false end
        if mode == "drop-error" then error("DND_FINAL_ERROR_SENTINEL") end
        return final
    end
end))
assert(window:show())
io.stdout:write("REAL_GTK_DND_READY\n"); io.stdout:flush()
assert(gui.run())
assert(dropped and ended)
if mode == "reject-then-move" then assert(#end_results == 2 and end_results[1] == false and end_results[2] == true) end
assert(deleted == (not rejected and expected == "move"), "unexpected source deletion")
-- GTK backends do not all emit drag-cancel after a drop callback refuses.
-- The source's deletion flag is the authoritative safety contract; the Python
-- harness also checks the binding's refusal diagnostic for mismatched actions.
if not rejected then
    assert(not cancelled, "accepted transfer was cancelled")
    assert(end_action == expected, tostring(end_action))
end
assert(window:close())
print("REAL_GTK_DND_OK:" .. mode)
