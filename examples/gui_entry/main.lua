-- Entry demonstration. Requires a GTK 4 runtime and a graphical session.
local gui = babet.gui
local ok, err = gui.init()
if not ok then
    io.stderr:write(tostring(err), "\n")
    return
end

local window = assert(gui.window {
    title = "Babet — Entry", width = 480, height = 240,
})
local column = assert(gui.box {orientation = "vertical", spacing = 8})
local entry = assert(gui.entry {placeholder = "Type a name, then press Enter"})
local preview = assert(gui.label("Current text: (empty)"))
local submitted = assert(gui.label("Nothing submitted yet"))
local toggle = assert(gui.button("Make read-only"))
local reset = assert(gui.button("Set text from Lua"))
local close = assert(gui.button("Close"))
local editable = true

assert(window:add(column))
for _, widget in ipairs {entry, preview, submitted, toggle, reset, close} do
    assert(column:add(widget))
end

assert(entry:onChanged(function()
    local text = entry:getText()
    assert(preview:setText("Current text: " .. (text == "" and "(empty)" or text)))
end))
assert(entry:onActivate(function()
    assert(submitted:setText("Submitted: " .. entry:getText()))
end))
assert(toggle:onClick(function()
    editable = not editable
    assert(entry:setEditable(editable))
    assert(toggle:setText(editable and "Make read-only" or "Allow editing"))
end))
assert(reset:onClick(function()
    -- Also works in read-only mode and updates the live preview.
    assert(entry:setText("Bonjour — été — 東京"))
end))
assert(close:onClick(function() assert(window:close()) end))
assert(window:show())
assert(gui.run())
