local g=babet.gui;assert(g.init());local w=assert(g.window{title='Babet events probe',width=200,height=100})
local label=assert(g.label('waiting'));assert(w:add(label));local sizes,exited,requests={},false,0
assert(w:onResize(function(width,height)
 assert(width>0 and height>0);sizes[#sizes+1]={width,height};if #sizes==1 then assert(w:setSizeRequest(400,260))end
end))
assert(w:onCloseRequest(function()requests=requests+1;return requests==1 end))
local p=assert(babet.spawn('/bin/sh',{'-c','exit 9'},{stdin='null',stdout='null',stderr='null'}))
assert(p:onExit(function(result,err)assert(result and result.code==9,err);exited=true;label:setText('finished')end))
local timedout=false;assert(g.timeout(5000,function()timedout=true;g.quit()end))
local function finish()
 if #sizes>=2 and exited then w:requestClose();assert(requests==1);w:requestClose()else g.timeout(25,finish)end
end
assert(g.idle(finish));assert(w:show());assert(g.run())
assert(not timedout and requests==2 and sizes[2][1]>sizes[1][1]and sizes[2][2]>sizes[1][2])
assert(p:wait(0).code==9);assert(p:close());print('REAL_EVENTS_OK')
