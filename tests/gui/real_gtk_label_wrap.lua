local gui = assert(babet.gui)
assert(gui.init())

-- Real-GTK regression for the note-display use case: a wrapped GtkLabel must
-- have a correct height-for-width allocation on its first rendered frame, not
-- only after a later interaction.  The fixed canvas mirrors free-positioned
-- note blocks used by applications.
local window = assert(gui.window {
    title = "Babet real GTK label wrap probe",
    width = 710,
    height = 360,
})
local fixed = assert(gui.fixed())
assert(window:add(fixed))

assert(gui.setCss([[
.wrap-probe {
    font-family: monospace;
    font-size: 20px;
}
]]))

local column = assert(gui.box {orientation = "vertical", spacing = 0})
assert(column:setSizeRequest(300, -1))
local label = assert(gui.label("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz01234567"))
assert(label:addClass("wrap-probe"))
assert(label:setWrap(true))
assert(label:setWrapMode("char"))
assert(label:setXAlign(0))
assert(label:setHExpand(true))
assert(column:add(label))
assert(fixed:put(column, 20, 20))

-- A one-line label using the same font gives us the actual line height of the
-- host GTK/Pango/font stack, avoiding hard-coded pixel assumptions.
local reference = assert(gui.label("reference"))
assert(reference:addClass("wrap-probe"))
assert(fixed:put(reference, 20, 270))

-- The harness clicks the centre of the window. Keep this button centred so the
-- test does not depend on toolkit theme geometry.
local widen = assert(gui.button("Widen"))
assert(widen:setSizeRequest(160, 80))
assert(fixed:put(widen, 275, 140))

local frame = assert(gui.drawingArea {width = 24, height = 24})
assert(fixed:put(frame, 650, 300))

local first_width, first_height, line_height
local widened = false
local checked_first = false

local function approximately_lines(height, single, lines)
    local expected = single * lines
    return math.abs(height - expected) <= math.max(3, math.floor(single * 0.15))
end

assert(frame:onDraw(function()
    local width, height = label:getSize()
    local _, ref_height = reference:getSize()
    assert(width > 0 and height > 0 and ref_height > 0)

    if not checked_first then
        -- With 60 monospace characters at 20 px and a 300 px note width, the
        -- label must already occupy three lines on the first rendered frame.
        assert(approximately_lines(height, ref_height, 3),
               string.format("first wrapped height is not 3 lines: width=%d height=%d line=%d",
                             width, height, ref_height))
        first_width, first_height, line_height = width, height, ref_height
        checked_first = true
        io.stdout:write("REAL_GTK_LABEL_WRAP_READY\n")
        io.stdout:flush()
        return
    end

    if widened then
        assert(width > first_width,
               string.format("label did not widen: first=%d current=%d", first_width, width))
        assert(height < first_height,
               string.format("label height did not shrink: first=%d current=%d", first_height, height))
        assert(approximately_lines(height, line_height, 2),
               string.format("widened wrapped height is not 2 lines: width=%d height=%d line=%d",
                             width, height, line_height))
        assert(gui.quit())
        io.stdout:write("REAL_GTK_LABEL_WRAP_OK\n")
        io.stdout:flush()
    end
end))

assert(widen:onClick(function()
    assert(checked_first, "widen click arrived before the first rendered frame")
    widened = true
    assert(column:setSizeRequest(450, -1))
    assert(frame:queueDraw())
end))

assert(window:show())
assert(gui.run())
assert(checked_first and widened)
assert(window:close())
