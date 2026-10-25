local g = babet.gui
assert(g.init())
local file, mode = arg[1], arg[2]
local function raises(fn) assert(not pcall(fn)) end
local p = assert(g.picture())
local w,h=p:getIntrinsicSize(); assert(w==0 and h==0)
for _,fn in ipairs({
 function() g.picture{unknown=true} end,
 function() g.picture{canShrink=1} end,
 function() g.picture{contentFit='bad'} end,
 function() p:setFile(42) end,
 function() p:setFile('a\0b') end,
 function() p:setContentFit('bad') end,
 function() p:setAlternativeText('\255') end,
 function() p:getIntrinsicSize(1) end,
 function() g.label('x'):setFile(file) end,
}) do raises(fn) end
assert(p:setCanShrink(false));assert(p:setAlternativeText('Photographie'));assert(p:setAlternativeText(nil))
assert(p:addClass('picture'));assert(p:setTooltipText('image'));assert(p:setSizeRequest(80,40))
assert(p:onPointer(function() end));assert(p:setDragData('image-1'));assert(p:setDragData(nil))
assert(p:onDrag(function() end));assert(p:onDrag(nil))
local ok,err=p:setFile(file)
if mode=='no-texture' then
 assert(ok==nil and err:find('4.6')); assert(p:setFile(nil))
 local v,e=g.picture{file=file};assert(v==nil and e:find('4.6'))
else
 assert(ok,err);w,h=p:getIntrinsicSize();assert(w==80 and h==40)
 local v,e=p:setFile(file..'.missing');assert(v==nil and type(e)=='string')
 w,h=p:getIntrinsicSize();assert(w==80 and h==40)
 v,e=p:setFile(arg[3]);assert(v==nil and type(e)=='string')
 local q=assert(g.picture{file=file,canShrink=false});assert(q:getIntrinsicSize()==80)
 assert(p:setFile(nil));w,h=p:getIntrinsicSize();assert(w==0 and h==0)
end
if mode=='no-fit' or mode=='no-texture' then
 local v,e=p:setContentFit('contain');assert(v==nil and e:find('4.8'))
 v,e=g.picture{contentFit='contain'};assert(v==nil and e:find('4.8'))
else for _,fit in ipairs{'fill','contain','cover','scale-down'} do assert(p:setContentFit(fit)) end end
p=nil;collectgarbage('collect');print('PICTURE_OK')
