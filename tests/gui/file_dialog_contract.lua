local g = babet.gui
assert(g.init())
local mode=arg[1]
local function cb() end
for _,fn in ipairs{
 function() g.openFile({},nil) end,
 function() g.openFile({bad=1},cb) end,
 function() g.openFile({name='x'},cb) end,
 function() g.saveFile({multiple=false},cb) end,
 function() g.openFile({parent=g.label('x')},cb) end,
 function() g.openFile({title='x\0y'},cb) end,
 function() g.openFile({title='\255'},cb) end,
 function() g.openFile({multiple=1},cb) end,
 function() g.openFile({filters={{patterns={[2]='x'}}}},cb) end,
 function() g.openFile({filters={{mimeTypes={42}}}},cb) end,
 function() g.openFile({filters={{bad=true}}},cb) end,
} do assert(not pcall(fn)) end
local opts={title='Choose image',folder='/tmp',filters={{name='Images',patterns={'*.png','*.jpg'},mimeTypes={'image/*'}}}}
if mode=='unavailable' or mode=='allocation' then
 local ok,err=g.openFile(opts,cb);assert(ok==nil and type(err)=='string')
 if mode=='unavailable' then assert(err:find('4.10')) end
 print('FILE_OK:'..mode);return
end
local called=0
if mode=='close-parent' or mode=='gc-parent' or mode=='quit' or mode=='close-state' then
 local win=assert(g.window());opts.parent=win
 assert(g.openFile(opts,function() error('CALLBACK_AFTER_CANCEL') end))
 if mode=='close-state' then print('FILE_OK:'..mode);return end
 if mode=='close-parent' then assert(win:close()) end
 if mode=='gc-parent' then opts.parent=nil;win=nil;collectgarbage('collect') end
 local w=assert(g.window());local b=assert(g.button('finish'));assert(w:add(b))
 assert(b:onClick(function() assert(called==0);if mode=='quit' then assert(g.quit()) else assert(w:close()) end end))
 assert(w:show());assert(g.run());if mode=='quit' then assert(w:close());assert(win:close()) end
 print('FILE_OK:'..mode);return
end
opts.multiple=mode=='multiple' or mode=='mixed'
local api=g.openFile
if mode=='save' then opts.multiple=nil;opts.name='saved.png';api=g.saveFile end
local function start() return api(opts,function(path,err)
 assert(select(2,coroutine.running()), "callback must use the main Lua thread")
 called=called+1
 if mode=='cancel' then assert(path==nil and err==nil)
 elseif mode=='error' then assert(path==nil and type(err)=='string')
 elseif mode=='remote' or mode=='mixed' then assert(path==nil and err=='babet.gui: file is not local')
 elseif mode=='multiple' then assert(#path==2 and path[1]=='/tmp/été image.png' and path[2]=='/tmp/b.png')
 else assert(path=='/tmp/été image.png' and err==nil) end
 if mode=='reentrant' then assert(g.openFile({},function(p) assert(p);called=called+1 end)) end
 if mode=='callback-error' then error('FILE_CALLBACK_SENTINEL') end
 if mode=='yield' then coroutine.yield() end
end) end
if mode=='coroutine' then
 local co=coroutine.create(start);local resumed,ok,err=coroutine.resume(co);assert(resumed and ok,err);co=nil
else assert(start()) end
collectgarbage('collect')
assert(g.run());assert(called==(mode=='reentrant' and 2 or 1))
print('FILE_OK:'..mode)
