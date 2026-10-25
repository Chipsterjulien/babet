local g=babet.gui;assert(g.init())
local mode=arg[1] or 'files'
local win=assert(g.window());local box=assert(g.box{orientation='vertical'});assert(win:add(box))
local target=assert(g.label('target'));assert(box:add(target));local done=assert(g.button('finish'));assert(box:add(done))
local function pair(a,b) assert(a==true and b==nil,tostring(b)) end
local function bad(a,b) assert(a==nil and type(b)=='string') end
for _,v in ipairs({{}, {'files','files'},{'unknown'},{'files',3},{'text',extra=1},{[1]='text',[3]='files'}}) do assert(not pcall(function()target:setDropTypes(v)end)) end
assert(not pcall(function() target:setDropTypes('files') end))
if mode=='unavailable' then bad(target:setDropTypes({'files'}));pair(target:setDropTypes({'text'}));pair(win:close());print('FILE_DROP_OK');return end
local types=(mode=='mixed' or mode=='mixed-delayed' or mode=='mixed-remote') and {'text','files'} or {'files'}
if mode~='default' and mode~='configure-late' then pair(target:setDropTypes(types)) end
local nested=mode=='nested' or mode=='nested-move-only' or mode=='nested-enter'
local both=mode=='source-copy' or mode=='hover-copy' or mode=='nested' or mode=='nested-enter'
pair(target:setDropActions(both and {'copy','move'} or mode=='nested-move-only' and 'move' or 'copy'))
if nested then
 -- Another process drops on the child: the child refuses hover, its parent
 -- accepts COPY, then GTK still delivers the drop to the child. With an
 -- enter-only transfer, GTK keeps the parent's MOVE over the child's COPY.
 pair(box:setDropTypes({'files'}));pair(box:setDropActions({'copy','move'}))
 pair(box:onDrop(function(phase)
  if phase=='drop' then error('NESTED_PARENT_DROP') end
  if phase~='leave' then return mode=='nested-enter' and 'move' or 'copy' end
 end))
end
local count,received=0,false
pair(target:onDrop(function(phase,payload,x,y,action,kind)
 count=count+1
 assert(mode~='default' and mode~='remote')
 -- Hover proposes MOVE to a COPY|MOVE source; drop reports the negotiated
 -- action, including one accepted by an ancestor, or nil if not allowed here.
 if phase~='drop' and (mode=='hover-copy' or nested) then assert(action=='move')
 elseif phase=='drop' and mode=='nested-move-only' then assert(action==nil)
 elseif phase=='drop' and mode=='nested-enter' then assert(action=='move')
 else assert(action=='copy') end
 assert(x==12 and y==18)
 if phase~='drop' and (mode=='delayed' or mode=='mixed-delayed') then
  assert(payload==nil);if mode=='mixed-delayed' then assert(kind==nil) else assert(kind=='files') end
 elseif mode=='mixed-remote' then assert(kind=='text' and payload=='https://example.org/first\nhttps://example.org/ignored\nsftp://host/file')
 else assert(kind=='files' and #payload==2 and payload[1]=='/tmp/image é.png' and payload[2]=='/tmp/second.png') end
 if mode=='reconfigure' then pair(target:setDropTypes({'text'}));return true end
 if mode=='disable' then pair(target:onDrop(nil));return true end
 if mode=='nested-enter' and phase~='drop' then return 'copy' end
 if mode=='hover-reject' or (nested and phase~='drop') then return false end
 if phase=='drop' then
  received=true;bad(target:setDropTypes({'text'}))
  if mode=='close' then pair(win:close());collectgarbage('collect');assert(payload[2]=='/tmp/second.png') end
  if mode=='callback-error' then error('FILE_DROP_SENTINEL') end
  if mode=='reject' then return false end
 end
 if mode=='hover-copy' then return 'copy' end
 if mode=='nested' or mode=='nested-enter' then return action end
 return true
end))
if mode=='configure-late' then pair(target:setDropTypes(types)) end
pair(done:onClick(function() pair(win:close()) end));pair(win:show());assert(g.run())
if mode=='default' or mode=='remote' then assert(count==0)
elseif mode=='disable' or mode=='reconfigure' then assert(count==1 and not received)
elseif mode=='hover-reject' then assert(count==2 and not received)
elseif mode=='nested-enter' then assert(count==2 and received) -- enter, then drop
else assert(count==3 and received) end
print('FILE_DROP_OK')
