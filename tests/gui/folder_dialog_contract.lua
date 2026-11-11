local g=babet.gui;assert(g.init());local mode=arg[1]
for _,opts in ipairs{{multiple=true},{name='x'},{filters={}},{unknown=true},{folder='x\0y'},{title='\255'}}do assert(not pcall(g.selectFolder,opts,function()end))end
local arity_ok,arity_err=pcall(g.selectFolder);assert(not arity_ok and arity_err:find('gui.selectFolder expects',1,true),arity_err)
-- Invalid native parents must identify the actual API, including dead handles.
-- Check all three entry points so fixing selectFolder preserves open/save errors.
do
 local label=assert(g.label('not a window'))
 local dead=assert(g.window());assert(dead:close())
 for _,api in ipairs{'selectFolder','openFile','saveFile'}do
  for _,parent in ipairs{label,dead}do
   local ok,err=pcall(g[api],{parent=parent},function()error('invalid parent callback')end)
   assert(not ok and err:find('gui.'..api..' parent:',1,true),tostring(err))
  end
 end
end
collectgarbage('collect')
local called=0
local function cb(path,e)
 called=called+1
 if mode=='cancel' then assert(path==nil and e==nil)
 elseif mode=='error' or mode=='remote' then assert(path==nil and type(e)=='string')
 else assert(path=='/tmp/été image.png' and e==nil)end
end
if mode=='close-parent' then
 local parent=assert(g.window());assert(g.selectFolder({parent=parent},function()error('late folder callback')end));parent:close()
 local w=assert(g.window());assert(w:show());assert(g.timeout(25,function()w:close()end));assert(g.run());assert(called==0)
else
 local ok,err=g.selectFolder({title='Choose folder',folder='/tmp'},cb)
 if mode=='unavailable' then assert(ok==nil and err:find('4.10'));assert(g.openFile({},function()called=called+1 end))else assert(ok,err)end
 assert(g.run());assert(called==1)
end
print('FOLDER_OK:'..mode)
