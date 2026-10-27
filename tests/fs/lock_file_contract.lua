local mode, path = assert(arg[1]), assert(arg[2])
local function packed(fn, ...)
    local values = table.pack(fn(...))
    assert(values.n == 2, 'expected exactly two return values')
    return values[1], values[2]
end
local function acquire(p)
    local h, err = packed(babet.lockFile, p)
    assert(type(h) == 'userdata' and err == nil, tostring(err))
    return h
end
local function ok(fn, ...)
    local value, err = packed(fn, ...)
    assert(value == true and err == nil, tostring(err))
end
local function busy(p)
    local h, err = packed(babet.lockFile, p)
    assert(h == nil and err == 'locked', tostring(err))
end
local function read()
    local f = assert(io.open(path, 'rb'))
    local text = assert(f:read('a')); assert(f:close()); return text
end

if mode == 'contract' then
    for _, args in ipairs({{}, {true}, {12}, {{}}, {''}, {'a\0b'}, {path, 1}}) do
        assert(not pcall(babet.lockFile, table.unpack(args)))
    end
    local h = acquire(path)
    assert(read() == '', 'new lock must start empty')
    assert(not pcall(h.close, h, 1))
    assert(not pcall(h.write, h))
    assert(not pcall(h.write, h, 1))
    assert(not pcall(h.write, h, 'a', 'b'))
    assert(not pcall(h.write, {}, 'a'))
    for _, text in ipairs({'PID 12345\n', 'é\0bin\255', 'x', ''}) do
        ok(h.write, h, text); assert(read() == text); busy(path)
    end
    ok(h.write, h, 'metadata')
    -- Closing an unrelated descriptor of this inode must NOT unlock flock.
    local f = assert(io.open(path, 'w')); assert(f:write('separate PID')); assert(f:close())
    busy(path)
    ok(h.close, h); ok(h.close, h)
    local value, err = packed(h.write, h, 'after close')
    assert(value == nil and type(err) == 'string')
    assert(read() == 'separate PID')
    do local guard <close> = acquire(path); busy(path) end
    do local guard <close> = acquire(path); assert(read() == 'separate PID') end
    assert(not pcall(function() local guard <close> = acquire(path); error('unwind') end))
    do local guard <close> = acquire(path) end
    do local forgotten = acquire(path); assert(forgotten) end
    collectgarbage('collect')
    do local guard <close> = acquire(path) end
    print('CONTRACT_OK')
elseif mode == 'hold' or mode == 'race' then
    if mode == 'race' then print('READY'); io.stdout:flush(); assert(io.read('l') == 'go') end
    local h, err = packed(babet.lockFile, path)
    if h then
        print('HELD'); io.stdout:flush(); assert(io.read('l') == 'close'); ok(h.close, h)
    else assert(err == 'locked', tostring(err)); print('LOCKED') end
elseif mode == 'try' then
    local h, err = packed(babet.lockFile, path)
    if h then ok(h.close, h); print('FREE')
    else assert(err == 'locked', tostring(err)); print('LOCKED') end
elseif mode == 'reject' then
    local h, err = packed(babet.lockFile, path)
    assert(h == nil and type(err) == 'string' and err ~= 'locked', tostring(err))
    print('REJECTED')
elseif mode == 'write' then
    local h <close> = acquire(path); ok(h.write, h, assert(arg[3])); print('WRITTEN')
elseif mode == 'launch' then
    keep_until_exit = acquire(path)
    assert(os.execute(assert(arg[3])))
    print('LAUNCHED')
elseif mode == 'workers' then
    local h <close> = acquire(path)
    local job = assert(babet.workers.spawn([[
        local path = assert(worker.args.path)
        local h, err = babet.lockFile(path)
        assert(h == nil and err == 'locked', tostring(err))
        keep_until_vm_close = assert(babet.lockFile(path .. '.worker'))
        assert(keep_until_vm_close:write('worker'))
        return true
    ]], {path = path}))
    local success, value = job:join(10); assert(success and value, tostring(value))
    busy(path) -- closing that worker's VM did not unlock this VM's handle
    local worker_file <close> = acquire(path .. '.worker')
    print('WORKERS_OK')
else error('unknown test mode') end
