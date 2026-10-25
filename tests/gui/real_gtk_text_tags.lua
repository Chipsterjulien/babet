local g=babet.gui;assert(g.init())
local win=assert(g.window{title='Babet text tags probe',width=400,height=180})
local box=assert(g.box{orientation='vertical'});assert(win:add(box))
local tv=assert(g.textView{text='Aé🙂Z',editable=false});assert(tv:setSizeRequest(380,90));assert(tv:setHExpand(true));assert(box:add(tv))
assert(tv:createTag('link',{foreground='#123abc',underline=true,weight=700,style='italic',scale=1.25}))
assert(tv:applyTag('link',2,7));assert(tv:setSensitive(false))
local probe=assert(g.drawingArea{width=1,height=1});assert(box:add(probe))
local ready=false
assert(probe:onDraw(function()
 if ready then return end
 local w,h=tv:getSize();assert(w>=380 and h>=90)
 assert(not pcall(function() tv:applyTag('link',1,1) end), 'tag mutation allowed in onDraw')
 local found={}
 for y=0,math.min(h-1,50),2 do
  for x=0,w-1,2 do
   local index=tv:offsetAt(x,y)
   if index then
    assert(index==1 or index==2 or index==4 or index==8,'middle of UTF-8 character')
    found[index]=true
    local tags=assert(tv:tagsAt(index));assert(#tags==((index==2 or index==4) and 1 or 0))
   end
  end
 end
 assert(found[1] and found[2] and found[4] and found[8],'hit testing did not find each glyph')
 assert(tv:offsetAt(w-1,h-1)==nil and tv:offsetAt(-1,0)==nil and tv:offsetAt(w,0)==nil)
 local a,b=tv:tagRange('link',4);assert(a==2 and b==7)
 ready=true;print('REAL_TAGS_READY');io.stdout:flush()
end))
assert(win:onKey(function(phase,key)
 if phase=='release' and key=='Escape' then assert(win:close()) end
 return false
end))
assert(win:show());assert(g.run());assert(ready);print('REAL_TAGS_OK')
