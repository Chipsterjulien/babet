-- Démonstration Babet GTK4 : notes posées librement, checklist et progression.
-- Exécuter sur un bureau GTK4 : babet examples/gui_free_notes/main.lua
local gui = babet.gui
local ok, err = gui.init()
assert(ok, err)

local window = assert(gui.window {title = "Notes libres — démo Babet", width = 940, height = 620})
local scroll = assert(gui.scrolledWindow())
local canvas = assert(gui.fixed())
assert(window:add(scroll))
assert(scroll:add(canvas))
canvas:setSizeRequest(1200, 850) -- zone navigable, indépendamment du contenu

local function note(title, body, x, y, width)
    local group = assert(gui.box {orientation = "vertical", spacing = 8})
    group:addClass("note")
    group:setSizeRequest(width, -1)
    local handle = assert(gui.label(title .. "    ⠿"))
    handle:addClass("note-title")
    local editor = assert(gui.textView {text = body})
    editor:setSizeRequest(-1, 105)
    assert(group:add(handle))
    assert(group:add(editor))
    assert(canvas:put(group, x, y))
    local start_x, start_y = x, y
    assert(handle:onDrag(function(phase, dx, dy)
        if phase == "begin" then
            start_x, start_y = x, y
        elseif phase == "update" or phase == "end" then
            x = math.max(0, start_x + dx)
            y = math.max(0, start_y + dy)
            assert(canvas:move(group, x, y))
        end
    end))
    return group, editor
end

local intro = note("Une idée", "Ce que je souhaite changer dans ma vie…", 35, 45, 320)
local tasks_box = assert(gui.box {orientation = "vertical", spacing = 8})
tasks_box:addClass("note")
tasks_box:setSizeRequest(300, -1)
local tasks_header = assert(gui.label("Actions   ⠿"))
local task1 = assert(gui.checkButton {label = "Choisir une activité", active = true})
local task2 = assert(gui.checkButton {label = "Prévoir un créneau"})
local task3 = assert(gui.checkButton {label = "Faire une première séance"})
local progress = assert(gui.progressBar())
progress:setShowText(true)
local checks = {task1, task2, task3}
local function refresh()
    local done = 0
    for _, c in ipairs(checks) do
        if c:getActive() then done = done + 1 end
    end
    progress:setFraction(done / #checks)
    progress:setText(('%d/%d actions'):format(done, #checks))
end
for _, c in ipairs(checks) do c:onChanged(refresh) end
for _, w in ipairs({tasks_header, task1, task2, task3, progress}) do
    assert(tasks_box:add(w))
end
refresh()
local tx, ty = 430, 110
assert(canvas:put(tasks_box, tx, ty))
local tx0, ty0 = tx, ty
assert(tasks_header:onDrag(function(phase, dx, dy)
    if phase == "begin" then
        tx0, ty0 = tx, ty
    elseif phase == "update" or phase == "end" then
        tx, ty = math.max(0, tx0 + dx), math.max(0, ty0 + dy)
        canvas:move(tasks_box, tx, ty)
    end
end))

local expander = assert(gui.expander {label = "Notes complémentaires", expanded = false})
local details = assert(gui.textView {text = "Des informations facultatives…"})
assert(expander:add(details))
expander:setSizeRequest(285, -1)
assert(canvas:put(expander, 100, 340))

assert(gui.setCss([[
.note { background: #f6f3e9; color: #292929; border: 1px solid #c7c0b5;
        border-radius: 9px; padding: 12px; }
.note-title { font-weight: bold; }
]]))
window:show()
gui.run()
