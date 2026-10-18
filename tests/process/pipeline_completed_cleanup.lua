-- Completed pipeline cleanup must not wait 500 ms in close, __close or __gc.
-- The Python harness runs one mode per Babet process and times it separately.
local mode = assert(arg[1], "missing cleanup mode")

local function completed()
    local p, err = babet.spawnPipeline({
        {"sh", {"-c", "exit 0"}},
        {"sh", {"-c", "exit 0"}},
    })
    assert(p, err)
    assert(p:wait(5))
    return p
end

if mode == "close" then
    local p = completed()
    assert(p:close())
elseif mode == "gc" then
    local p = completed()
    p = nil
    collectgarbage("collect")
    collectgarbage("collect")
elseif mode == "scope" then
    do
        local p <close> = completed()
    end
else
    error("unknown cleanup mode: " .. tostring(mode))
end

print("PIPELINE_COMPLETED_CLEANUP_OK", mode)
