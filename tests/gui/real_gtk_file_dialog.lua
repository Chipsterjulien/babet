local g=babet.gui; assert(g.init())
local mode,folder=arg[1],arg[2]
local opts={title='Babet file probe',folder=folder,filters={{name='Images',patterns={'*.png'},mimeTypes={'image/png'}}}}
local fn=g.openFile
if mode=='save' then fn=g.saveFile;opts.name='saved.png'
elseif mode=='multiple' then opts.multiple=true end
local calls=0
local ok,err=fn(opts,function(path,e)
 calls=calls+1
 if mode=='cancel' then assert(path==nil and e==nil)
 elseif mode=='multiple' then assert(type(path)=='table' and #path==1 and path[1]==folder..'/image.png')
 else assert(path==folder..(mode=='save' and '/saved.png' or '/image.png'),tostring(path)..' / '..tostring(e)) end
end)
if not ok and err:find('requires GTK',1,true) then print('REAL_FILES_SKIP:'..err);return end
assert(ok,err);print('REAL_FILES_READY');io.stdout:flush()
assert(g.run());assert(calls==1);print('REAL_FILES_OK:'..mode)
