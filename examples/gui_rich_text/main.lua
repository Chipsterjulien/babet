-- Generic text annotations and file selection by native drag-and-drop.
local gui=babet.gui;assert(gui.init())
local window=assert(gui.window{title='Text and files',width=620,height=260})
local box=assert(gui.box{orientation='vertical',spacing=12});assert(box:setMargins(16));assert(window:add(box))
local text='Café — https://example.org\nClick the underlined link to display it below.'
local view=assert(gui.textView{text=text,editable=false,wrap='word-char'})
assert(view:setVExpand(true));assert(box:add(view))
assert(view:createTag('link',{foreground='#1565c0',underline=true}))
local first,last=text:find('https://example.org',1,true);assert(view:applyTag('link',first,last))
local status=assert(gui.label('Drop files here (GTK 4.6 or newer).'))
assert(box:add(status))
assert(view:onPointer(function(phase,x,y,button)
 if phase~='release' or button~=1 then return end
 local index=view:offsetAt(x,y);if not index then return end
 local a,b=view:tagRange('link',index)
 if a then assert(status:setText(view:getText():sub(a,b))) end
end))
local enabled,err=status:setDropTypes({'files'})
if enabled then
 assert(status:setDropActions('copy'))
 assert(status:onDrop(function(phase,paths,x,y,action,kind)
  if phase=='drop' then
   if kind~='files' or action~='copy' then return false end
   -- Display only: no files are modified by this example.
   assert(status:setText(tostring(#paths)..' local file(s) selected'))
   for _,path in ipairs(paths) do print(path) end
  end
  return true
 end))
else assert(status:setText(err)) end
local close=assert(gui.button('Close'));assert(box:add(close))
assert(close:onClick(function() assert(window:close()) end))
assert(window:show());assert(gui.run())
