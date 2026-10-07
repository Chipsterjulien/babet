local gui = babet.gui
assert(gui.init())

local window = assert(gui.window {title = "Courbe native GTK", width = 740, height = 450})
local column = assert(gui.box {spacing = 10})
local title = assert(gui.label("Évolution du poids - données de démonstration"))
local area = assert(gui.drawingArea {width = 700, height = 340})
local buttons = assert(gui.box {orientation = "horizontal", spacing = 10})
local change = assert(gui.button("Changer les données"))
local close = assert(gui.button("Fermer"))
assert(window:add(column))
assert(column:add(title))
assert(column:add(area))
assert(column:add(buttons))
assert(buttons:add(change))
assert(buttons:add(close))

local function point(day, value)
    return {time = os.time {year = 2026, month = 10, day = day, hour = 12}, value = value}
end
local sets = {
    {point(1, 91.4), point(3, 91.1), point(7, 90.8), point(8, 91.0), point(12, 90.5)},
    {point(1, 89.2), point(4, 89.4), point(5, 89.0), point(10, 88.8), point(15, 88.6)},
}
local selected = 1

assert(area:onDraw(function(ctx, width, height)
    local points = sets[selected] -- sorted by time; gaps retain their actual duration
    local low, high = points[1].value, points[1].value
    for _, p in ipairs(points) do low = math.min(low, p.value); high = math.max(high, p.value) end
    low, high = math.floor((low - 0.3) * 2) / 2, math.ceil((high + 0.3) * 2) / 2
    local left, top, right, bottom = 62, 28, width - 34, height - 42
    local first, last = points[1].time, points[#points].time
    local function x(t) return left + (t - first) / math.max(last - first, 1) * (right - left) end
    local function y(value) return bottom - (value - low) / (high - low) * (bottom - top) end

    assert(ctx:setSourceRGB(1, 1, 1))
    assert(ctx:rectangle(0, 0, width, height)); assert(ctx:fill())
    assert(ctx:setFontSize(12))
    for i = 0, 4 do
        local value = low + i * (high - low) / 4
        assert(ctx:setSourceRGB(0.86, 0.88, 0.91)); assert(ctx:setLineWidth(1))
        assert(ctx:moveTo(left, y(value))); assert(ctx:lineTo(right, y(value))); assert(ctx:stroke())
        assert(ctx:setSourceRGB(0.22, 0.25, 0.30))
        assert(ctx:text(8, y(value) + 4, string.format("%.1f", value)))
    end
    assert(ctx:text(8, 16, "kg"))
    assert(ctx:moveTo(left, top)); assert(ctx:lineTo(left, bottom))
    assert(ctx:lineTo(right, bottom)); assert(ctx:stroke())
    assert(ctx:text(left, height - 14, os.date("%d/%m", first)))
    assert(ctx:text(right - 34, height - 14, os.date("%d/%m", last)))

    assert(ctx:newPath()); assert(ctx:setSourceRGB(0.10, 0.37, 0.76)); assert(ctx:setLineWidth(2.5))
    for i, p in ipairs(points) do
        if i == 1 then assert(ctx:moveTo(x(p.time), y(p.value)))
        else assert(ctx:lineTo(x(p.time), y(p.value))) end
    end
    assert(ctx:stroke())
    for _, p in ipairs(points) do
        assert(ctx:arc(x(p.time), y(p.value), 4, 0, 2 * math.pi)); assert(ctx:fill())
    end
end))
assert(change:onClick(function()
    selected = 3 - selected
    assert(area:queueDraw())
end))
assert(close:onClick(function() assert(window:close()) end))
assert(window:show())
assert(gui.run())
