local probe = assert(os.getenv("BABET_TEST_SIGNAL_PROBE"))
local source = [=[
local probe = ...
local function own_mask()
    local f = assert(io.open("/proc/thread-self/status", "r"))
    local text = f:read("a"); f:close()
    return assert(text:match("SigBlk:%s*(%x+)"))
end
local before = own_mask()
local function check(result, term)
    if term then
        assert(result.code == 143, "child must terminate through SIGTERM")
    else
        assert(result.code == 0, "child inherited blocked signals")
    end
end
for _, term in ipairs({false, true}) do
    local args = term and {"--term"} or {}
    local r = assert(babet.exec(probe, args, {timeout=3}))
    check(r, term)
    if not term then assert(r.stdout == "unblocked\n") end

    local p = assert(babet.spawn(probe, args))
    check(assert(p:wait(3)), term)
    p:close()

    local stages = {{probe, args}, {"cat"}}
    r = assert(babet.pipeline(stages, {timeout=3}))
    check(r.stages[1], term)
    assert(r.stages[2].code == 0)

    p = assert(babet.spawnPipeline(stages))
    r = assert(p:wait(3))
    check(r.stages[1], term)
    assert(r.stages[2].code == 0)
    p:close()
end
assert(own_mask() == before, "launch changed the caller's signal mask")
return true
]=]
assert(assert(load(source))(probe))
print("[PASS] exec/spawn/pipeline/spawnPipeline start unblocked and receive SIGTERM (main)")
local job = assert(babet.workers.spawn(
    "local run = function(...)\n" .. source .. "\nend; return run(worker.args.probe)", {probe=probe}))
local ok, result = job:join(10)
assert(ok == true and result == true, tostring(result))
print("[PASS] exec/spawn/pipeline/spawnPipeline start unblocked and receive SIGTERM (worker)")
