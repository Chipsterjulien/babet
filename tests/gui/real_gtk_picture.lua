local g=babet.gui; assert(g.init())
local p,err=g.picture{file=arg[1]}
if not p and err:find('requires GTK',1,true) then print('REAL_FILES_SKIP:'..err);return end
assert(p,err)
local w,h=p:getIntrinsicSize();assert(w==80 and h==40)
assert(p:setFile(arg[2]));w,h=p:getIntrinsicSize();assert(w==80 and h==40)
assert(p:setFile(arg[1]));local ok,e=p:setFile(arg[1]..'.missing');assert(ok==nil and e)
w,h=p:getIntrinsicSize();assert(w==80 and h==40)
assert(p:setAlternativeText('Red test image'));assert(p:setHExpand(true))
local win=assert(g.window{title='Babet picture probe',width=320})
local box=assert(g.box{orientation='vertical'});assert(win:add(box));assert(box:add(p))
local probe=assert(g.drawingArea{width=1,height=1});assert(box:add(probe))
local ready=false
assert(probe:onDraw(function()
 if not ready then
  local width,height=p:getSize()
  assert(width>=300 and math.abs(height-width/2)<=2, string.format('aspect allocation %d x %d',width,height))
  ready=true;print('REAL_FILES_READY');io.stdout:flush()
 end
end))
assert(win:onKey(function(phase,key)
 if phase=='release' and key=='Escape' then assert(win:close()) end
 return false
end))
assert(win:show());assert(g.run());assert(ready);print('REAL_FILES_OK:picture')
