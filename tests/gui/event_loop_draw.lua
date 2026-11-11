local g=babet.gui;assert(g.init());local w=assert(g.window())
local area=assert(g.drawingArea{width=50,height=50});assert(w:add(area));local drew,deferred=false,false
assert(area:onDraw(function()
 if drew then return end;drew=true
 assert(not pcall(function()area:setSizeRequest(70,70)end))
 assert(g.idle(function()assert(area:setSizeRequest(70,70));deferred=true;w:close()end))
end))
assert(w:show());assert(g.timeout(2000,function()g.quit()end));assert(g.run());assert(drew and deferred);print('EVENT_DRAW_OK')
