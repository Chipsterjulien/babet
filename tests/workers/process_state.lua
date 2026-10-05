-- Each scenario runs in a fresh process: the locale freeze is process-wide.
local W = babet.workers
local count = 0
local function check(name, fn)
    fn()
    count = count + 1
    print('[PASS] ' .. name)
end
local function joined(code, args)
    local job = assert(W.spawn(code, args))
    local ok, value = job:join(10)
    assert(ok == true, tostring(value))
    return value
end
local function denied(fn, ...)
    local ok, err = pcall(fn, ...)
    assert(not ok and type(err) == 'string' and err:find('workers.spawn', 1, true), tostring(err))
end

if arg[1] == 'exit' then
    local sibling = assert(W.spawn([[local ok,v=worker.recv(10); assert(ok); return v]]))
    local variants = {
        'os.exit()', 'os.exit(23)', 'os.exit(true)', 'os.exit(false)',
        'os.exit(23, true)', 'os.exit(nil, true)',
        'require("os").exit(23)',
        'local exit=os.exit; exit(23)',
        'coroutine.wrap(function() os.exit(23, true) end)()',
    }
    for _, code in ipairs(variants) do
        check('worker rejects ' .. code, function()
            local job = assert(W.spawn(code))
            local ok, err = job:join(10)
            assert(ok == false and err:find('os.exit: unavailable in a worker', 1, true), tostring(err))
            assert(job:status() == 'error')
            local received, reason = job:recv(0)
            assert(received == false and reason == 'closed')
        end)
    end
    check('sibling survives attempted exits', function()
        assert(sibling:send('alive', 5))
        local ok, value = sibling:join(10)
        assert(ok and value == 'alive')
    end)
    check('caught exit leaves worker and queues usable', function()
        local job = assert(W.spawn([[
            local ok, err = pcall(os.exit, 23, true)
            assert(not ok and err:find('os.exit',1,true))
            assert(worker.send('recovered', 5))
            return 42
        ]]))
        local received, value = job:recv(10)
        assert(received and value == 'recovered')
        local ok, result = job:join(10)
        assert(ok and result == 42)
    end)
    check('coroutine exit does not close worker state', function()
        assert(joined([[
            local c=coroutine.create(function() os.exit(23, true) end)
            local ok,err=coroutine.resume(c)
            assert(not ok and err:find('os.exit',1,true))
            return coroutine.status(c)=='dead'
        ]]))
    end)
    check('nested worker exit is contained', function()
        assert(joined([[
            local child=assert(babet.workers.spawn('os.exit(23, true)'))
            local ok,err=child:join(10)
            return ok==false and err:find('os.exit',1,true)~=nil
        ]]))
    end)
    check('exit in a finalizer cannot terminate the process', function()
        assert(joined([[
            local finalized=false
            do local t=setmetatable({}, {__gc=function()
                finalized=true; os.exit(23, true)
            end}) end
            collectgarbage('collect')
            return finalized
        ]]))
    end)
    check('exit during state shutdown cannot terminate the process', function()
        assert(joined([[
            keep_until_close=setmetatable({}, {__gc=function() os.exit(23, true) end})
            return true
        ]]))
    end)
elseif arg[1] == 'locale' then
    local categories = {'all', 'collate', 'ctype', 'monetary', 'numeric', 'time'}
    local saved = os.setlocale
    check('standard locale defaults and return arity before spawn', function()
        assert(select('#', saved('C')) == 1)
        assert(saved() == 'C' and saved(nil, 'all') == 'C')
        for _, cat in ipairs(categories) do assert(saved('C', cat) == 'C') end
    end)
    check('unavailable locale returns one nil without changing locale', function()
        assert(select('#', saved('babet_nonexistent_locale_987654321')) == 1)
        assert(saved('babet_nonexistent_locale_987654321') == nil)
        assert(saved() == 'C')
    end)
    check('bad locale arguments do not leave the mutex locked', function()
        assert(not pcall(saved, {}))
        assert(not pcall(saved, nil, 'unknown'))
        assert(saved('C') == 'C')
    end)
    check('invalid spawn arguments do not freeze the locale', function()
        assert(not pcall(W.spawn, 42))
        assert(not pcall(W.spawn, 'return true', nil, {inbox_capacity=1.5}))
        assert(saved('C') == 'C')
    end)
    -- Exercise libc's composite LC_ALL storage where an extra locale exists.
    -- No locale package is required: the C-only path remains a valid test.
    saved('C.UTF-8', 'ctype')
    local snapshot = {}
    for _, cat in ipairs(categories) do snapshot[cat] = assert(saved(nil, cat)) end
    local waiter = assert(W.spawn([[local ok=worker.recv(10); assert(ok); return true]]))
    check('main state and saved aliases reject all locale mutations', function()
        for _, cat in ipairs(categories) do
            denied(saved, 'C', cat)
            denied(os.setlocale, '', cat)
        end
        denied(require('os').setlocale, 'C')
        assert(saved() == snapshot.all)
    end)
    check('workers reject locale mutations and preserve queries', function()
        assert(joined([[
            for _, cat in ipairs({'all','collate','ctype','monetary','numeric','time'}) do
                local ok,err=pcall(os.setlocale,'C',cat)
                assert(not ok and err:find('workers.spawn',1,true))
                assert(os.setlocale(nil,cat)==worker.args[cat])
            end
            return require('os').setlocale()==worker.args.all
        ]], snapshot))
    end)
    check('concurrent locale queries return stable copied values', function()
        local jobs = {}
        for i = 1, 6 do
            jobs[i] = assert(W.spawn([[
                for i=1,300 do
                    for cat,value in pairs(worker.args) do
                        assert(os.setlocale(nil,cat)==value,cat)
                    end
                    assert(tonumber('12.5')==12.5)
                end
                return true
            ]], snapshot))
        end
        for i=1,300 do assert(saved()==snapshot.all) end
        for _, job in ipairs(jobs) do local ok,v=job:join(10); assert(ok and v,tostring(v)) end
    end)
    check('nested workers enforce the same locale policy', function()
        assert(joined([[
            local child=assert(babet.workers.spawn([=[
                local ok,err=pcall(os.setlocale,'C')
                return not ok and err:find('workers.spawn',1,true)~=nil
            ]=]))
            local ok,v=child:join(10); assert(ok,tostring(v)); return v
        ]]))
    end)
    check('locale remains frozen after every worker has joined', function()
        assert(waiter:send(true, 5))
        assert(waiter:join(10))
        denied(saved, 'C')
        assert(saved()==snapshot.all)
    end)
elseif arg[1] == 'failed-spawn' then
    check('serialization failure still freezes locale before thread creation', function()
        assert(os.setlocale('C') == 'C')
        local cycle = {}; cycle.self = cycle
        local job, err = W.spawn('return true', cycle)
        assert(job == nil and type(err)=='string', tostring(err))
        denied(os.setlocale, 'C')
        assert(os.setlocale() == 'C')
    end)
elseif arg[1] == 'main-exit' then
    local forms = {
        code = function() os.exit(23) end,
        close = function() os.exit(23, true) end,
        yes = function() os.exit(true) end,
        no = function() os.exit(false) end,
        default = function() os.exit() end,
    }
    assert(forms[arg[2]])()
    error('main os.exit returned')
else
    error('unknown process-state scenario: ' .. tostring(arg[1]))
end
print(('Process state: %d PASS'):format(count))
