local merge = babet.mergeTables
local count = 0
local function check(name, fn)
    fn(); count = count + 1; print('[PASS] ' .. name)
end
local function same(actual, expected)
    assert(getmetatable(actual) == nil)
    for k, v in next, expected do assert(rawequal(actual[k], v), tostring(k)) end
    for k, v in next, actual do assert(rawequal(expected[k], v), tostring(k)) end
end
local function reference(...)
    local result, last = {}, 0
    for _, source in ipairs({...}) do
        local keys = {}
        for key in next, source do
            if math.type(key) == 'integer' and key > 0 then keys[#keys + 1] = key end
        end
        table.sort(keys)
        for _, key in ipairs(keys) do last = last + 1; result[last] = rawget(source, key) end
        for key, value in next, source do
            if math.type(key) ~= 'integer' or key <= 0 then result[key] = value end
        end
    end
    return result
end
check('argument validation and one-result contract', function()
    assert(not pcall(merge)); assert(not pcall(merge, {})); assert(not pcall(merge, {}, 42))
    assert(select('#', merge({}, {})) == 1)
end)
check('empty tables', function() same(merge({}, {}, {}), {}) end)
check('dense sources append in argument order', function()
    same(merge({1,2,3}, {}, {4,5}), {1,2,3,4,5})
end)
check('holes compact independently of table length borders', function()
    same(merge({[1]='a',[4]='d',[8]='h'}, {[2]='b',[5]='e'}), {'a','d','h','b','e'})
end)
check('very large integer keys stay exact', function()
    local high = math.maxinteger
    same(merge({[high]='max',[high-1]='previous',[1]='first'}, {}), {'first','previous','max'})
end)
check('64-bit keys do not narrow to a 32-bit dense length', function()
    same(merge({[4294967297]='wide'}, {}), {'wide'})
end)
check('integer-valued floats are list keys', function()
    same(merge({[2.0]='b',[1.0]='a'}, {[3]='c'}), {'a','b','c'})
end)
check('map keys retain identity and last-writer-wins', function()
    local table_key, fn = {}, function() end
    local a = {[table_key]='a',[fn]='a',[true]='a',[false]='a',[0]='a',[-3]='a',[1.5]='a',['1']='a'}
    local b = {}; for key in next, a do b[key]='b' end
    same(merge(a,b),b)
end)
check('infinities and out-of-range integer floats remain map keys', function()
    local source = {[math.huge]='p',[-math.huge]='n',[1e30]='large',[math.mininteger]='min'}
    same(merge(source, {}), source)
end)
check('false values are preserved', function()
    same(merge({false,false,label=false}, {[5]=false}), {false,false,false,label=false})
end)
check('mixed dense and sparse lists retain map overwrites', function()
    same(merge({1,2,name='old'}, {[100]=3,name='new'}), {1,2,3,name='new'})
end)
check('subtables are shared and source tables stay unchanged', function()
    local child={}; local a={[7]=child, child=child}; local b={child=child}
    local result=merge(a,b); assert(result[1]==child and result.child==child)
    assert(a[7]==child and a[1]==nil and b[1]==nil)
end)
check('repeated sources and cycles are shallow', function()
    local source={}; source[3]=source; source.self=source
    local result=merge(source,source)
    assert(result[1]==source and result[2]==source and result.self==source)
end)
check('source metamethods are never invoked', function()
    local function forbidden() error('unexpected metamethod') end
    local mt={__len=forbidden,__pairs=forbidden,__index=forbidden,__newindex=forbidden,__lt=forbidden}
    local a=setmetatable({[4]='d',[1]='a',name='x'},mt)
    same(merge(a,setmetatable({'z'},mt)),{'a','d','z',name='x'})
end)
check('large dense lists preserve every element', function()
    local a={}; for i=1,20000 do a[i]=i end
    local result=merge(a,a); assert(#result==40000)
    for i=1,40000 do assert(result[i]==(i-1)%20000+1) end
end)
check('large sparse lists sort all keys', function()
    local a={}; for i=10000,1,-1 do a[i*17]=i end
    local result=merge(a,{}); assert(#result==10000)
    for i=1,10000 do assert(result[i]==i) end
end)
check('deterministic varied tables match an independent reference', function()
    local seed=12345
    local function random(n) seed=(seed*16807)%2147483647; return seed%n end
    for round=1,250 do
        local a,b={},{}
        for i=1,random(100) do a[random(1000)+1]=i end
        for i=1,random(100) do b[random(1000)+1]=-i end
        a.label='left'; b.label='right'; a[-round]=true; b[0]=false
        same(merge(a,b),reference(a,b))
    end
end)
print(('mergeTables contracts: %d PASS / 0 FAIL'):format(count))
