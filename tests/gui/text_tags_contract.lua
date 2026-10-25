local g=babet.gui; assert(g.init())
local mode=arg[1] or 'full'
local tv=assert(g.textView{text='Aé🙂Z\nfin',editable=false})
local function pair(ok,err) assert(ok==true and err==nil,tostring(err)) end
local function fails(fn) local ok,err=pcall(fn);assert(not ok and err) end
local function bad(a,b) assert(a==nil and type(b)=='string',tostring(a)) end
if mode=='unavailable' then bad(tv:createTag('x',{})); print('TEXT_TAGS_OK');return end
if mode=='allocation' then bad(tv:createTag('x',{}));print('TEXT_TAGS_OK');return end
pair(tv:createTag('link',{foreground='#123abc',background='#abcdef',underline=true,strikethrough=true,weight=700,style='italic',scale=1.25}))
pair(tv:createTag('second',{}))
bad(tv:createTag('link',{}));bad(tv:createTag('x',{unknown=true}));bad(tv:createTag('x',{['']=true}))
for _,props in ipairs({{weight=99},{weight=901},{weight=1.2},{scale=0},{scale=0/0},{scale=math.huge},{foreground='red'},{background='#xyz123'},{underline=1},{strikethrough='yes'},{style='bold'}}) do fails(function() tv:createTag('bad',props) end) end
fails(function() tv:createTag('',{}) end);fails(function() tv:createTag('x',{},4) end)
local function range(name,index,a,b) local x,y=tv:tagRange(name,index); assert(x==a and y==b,tostring(x)..','..tostring(y)) end
pair(tv:applyTag('link',2,7));pair(tv:applyTag('second',4,8))
assert(table.concat(tv:tagsAt(2),',')=='link');assert(table.concat(tv:tagsAt(4),',')=='link,second')
range('link',4,2,7);range('second',8,4,8);assert(select('#',tv:tagRange('link',1))==1);assert(tv:tagRange('link',1)==nil)
pair(tv:removeTag('link',4,7));range('link',2,2,3);assert(tv:tagRange('link',4)==nil)
pair(tv:applyTag('link',4,7));range('link',2,2,7)
pair(tv:applyTag('link',9,12));range('link',12,9,12)
for _,span in ipairs({{0,1},{3,3},{4,6},{5,7},{2,2},{8,7},{1,13},{math.maxinteger,math.maxinteger}}) do bad(tv:applyTag('link',span[1],span[2]));bad(tv:removeTag('link',span[1],span[2])) end
for _,i in ipairs({0,3,5,6,7,13,math.maxinteger}) do bad(tv:tagsAt(i));bad(tv:tagRange('link',i)) end
bad(tv:applyTag('missing',1,1));bad(tv:tagRange('missing',1))
pair(tv:removeAllTags());assert(#tv:tagsAt(2)==0)
pair(tv:applyTag('link',1,12));pair(tv:setText('Aé🙂Z\nfin'));assert(#tv:tagsAt(2)==0);pair(tv:applyTag('link',2,3))
pair(tv:setSensitive(false));range('link',2,2,3)
if mode=='full' then
 pair(tv:setSizeRequest(200,100));assert(tv:offsetAt(3,5)==1);assert(tv:offsetAt(11,5)==2);assert(tv:offsetAt(19,5)==4)
 assert(tv:offsetAt(-1,5)==nil and tv:offsetAt(190,5)==nil and tv:offsetAt(3,90)==nil)
end
fails(function() tv:offsetAt(0/0,1) end)
pair(tv:setText(''));assert(tv:offsetAt(1,1)==nil);bad(tv:applyTag('link',1,1));bad(tv:tagsAt(1))
pair(tv:setText('é'));pair(tv:applyTag('link',1,2));range('link',1,1,2)
tv=nil;collectgarbage('collect');print('TEXT_TAGS_OK')
