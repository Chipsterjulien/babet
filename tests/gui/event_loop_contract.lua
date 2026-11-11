local g=babet.gui;assert(g.init())
for _,fn in ipairs{
 function()g.timeout(-1,function()end)end,function()g.timeout(1.5,function()end)end,
 function()g.timeout(0,nil)end,function()g.idle(nil)end,function()g.cancel('1')end,function()g.onError(1)end,
}do assert(not pcall(fn))end
local w=assert(g.window{width=200,height=100})
local ready,exited,cached_seen,expired=false,false,false,false
local resized,veto,errors=0,0,0
assert(g.onError(function(e)assert(e:find('TIMER_ERROR',1,true)and e:find('stack traceback',1,true));errors=errors+1 end))
assert(g.timeout(4000,function()expired=true;g.quit()end))
local id=assert(g.timeout(0,function()error('cancelled callback')end));assert(g.cancel(id));assert(g.cancel(id)==false)
assert(g.timeout(0,function()error('TIMER_ERROR')end))
assert(w:onResize(function(width,height)assert(width>0 and height>0);resized=resized+1;if resized==1 then assert(w:setSizeRequest(280,160))end end))
assert(w:onCloseRequest(function()veto=veto+1;return veto==1 end))
-- gtk_window_close() ignores a window that was never shown: nothing is emitted.
assert(w:requestClose());assert(veto==0)
assert(w:show());assert(w:requestClose());assert(veto==1)
local opts={stdin='null',stdout='null',stderr='null'}
local proc=assert(babet.spawn('/bin/sh',{'-c','exit 7'},opts))
local old=assert(proc:onExit(function()error('replaced observer')end))
local observer=assert(proc:onExit(function(result,err)assert(err==nil and result.code==7 and result.exited);exited=true;assert(proc:wait(0).code==7)end))
assert(observer>old and g.cancel(old)==false)
local cached=assert(babet.spawn('/bin/sh',{'-c','exit 3'},opts));assert(cached:wait().code==3)
assert(cached:onExit(function(r)assert(r.code==3);cached_seen=true end))
local removed=assert(babet.spawn('/bin/true',{},opts));assert(removed:onExit(function()error('removed observer')end));assert(removed:onExit(nil))
local co=coroutine.create(function()assert(g.idle(function()assert(select(2,coroutine.running()));ready=true end))end);assert(coroutine.resume(co))
local function finish()
 if ready and exited and cached_seen and resized>=2 and errors==1 then assert(w:requestClose())else assert(g.timeout(10,finish))end
end
assert(g.idle(finish));assert(g.run())
assert(not expired and ready and exited and cached_seen and errors==1 and resized>=2 and veto==2)
assert(removed:wait());assert(proc:close());assert(cached:close());assert(removed:close());assert(g.onError(nil))
local nextw=assert(g.window());assert(nextw:show());assert(g.timeout(30,function()nextw:close()end));assert(g.run())
print('EVENT_LOOP_OK')
