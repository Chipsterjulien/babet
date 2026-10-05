-- File-backed rollback-journal locking, with GC stopped: a surviving cursor
-- is observable by another connection, without inspecting implementation.
collectgarbage("stop")
local path = assert(arg[1])
local db = assert(babet.sqlite.open(path, {busy_timeout=0}))
local writer = assert(babet.sqlite.open(path, {busy_timeout=0}))
assert(db:exec("CREATE TABLE t(v); INSERT INTO t VALUES(1),(2),(3)"))
local sql = "SELECT v FROM t"
local passed = 0
local function pass(name)
    passed = passed + 1
    print("[PASS] " .. name)
end
local function writable(name)
    local ok, err = writer:exec("INSERT INTO t VALUES(42)")
    assert(ok, name .. ": " .. tostring(err))
    pass(name)
end
local function locked()
    local ok, err = writer:exec("INSERT INTO t VALUES(42)")
    assert(ok == nil and type(err) == "string" and err:find("locked", 1, true), tostring(err))
end

for row in db:query(sql) do assert(row.v); break end
writable("generic for break releases read lock")

local function early_return()
    for row in db:query(sql) do return row.v end
end
assert(early_return())
writable("generic for return releases read lock")

do
    for row in db:query(sql) do assert(row.v); goto finished end
    ::finished::
end
writable("generic for goto releases read lock")

local sentinel = {}
local ok, err = pcall(function()
    for row in db:query(sql) do assert(row.v); error(sentinel) end
end)
assert(not ok and err == sentinel, "__close masked the original error")
writable("generic for error releases lock and preserves error object")

for row in assert(db:query(sql)) do assert(row.v); break end
writable("assert preserves the generic-for closing value")

local kept
do
    local iter <close> = assert(db:query(sql))
    kept = iter
    assert(iter().v)
    locked()
end
assert(kept() == nil)
assert(kept:close())
writable("to-be-closed local finalizes without destroying surviving userdata")

local ok, err = pcall(function()
    local iter <close> = assert(db:query(sql))
    assert(iter().v)
    error(sentinel)
end)
assert(not ok and err == sentinel)
writable("to-be-closed local preserves exception")

local co = coroutine.create(function()
    for row in db:query(sql) do coroutine.yield(row.v) end
end)
assert(coroutine.resume(co))
locked()
assert(coroutine.close(co))
writable("coroutine.close finalizes a suspended generic-for cursor")

local iter, state, control, closing = db:query(sql)
assert(type(iter) == "userdata" and state == nil and control == nil and closing == iter)
assert(select("#", db:query("-- empty")) == 4)
iter:close()
local failure = table.pack(db:query("SELECT FROM"))
assert(failure.n == 2 and failure[1] == nil and type(failure[2]) == "string")
pass("query return tuple and nil/error failure contract")

-- Storing only the first result intentionally drops the generic-for closer.
local manual = assert(db:query(sql))
for row in manual do assert(row.v); break end
locked()
assert(manual:close())
assert(manual:close())
assert(manual() == nil)
writable("standalone iterator retains explicit idempotent close contract")

local values = table.pack(db:query(sql))
for row in values[1], values[2], values[3], values[4] do assert(row.v); break end
assert(values[1]() == nil and values[4]:close())
writable("retained generic-for iterator is closed after break")

for row in db:query(sql) do assert(row.v) end
writable("normal exhaustion and subsequent __close are idempotent")
for _ in db:query("-- empty") do error("unexpected row") end
writable("empty query closing value is safe")

local statement = assert(db:prepare("SELECT v FROM t WHERE v >= ?"))
assert(select("#", statement:query({1})) == 1)
for row in statement do assert(row.v); break end
locked()
assert(statement:reset())
writable("prepared statement remains reusable after break and reset")
for row in statement:query({2}) do assert(row.v >= 2); break end
assert(statement:reset())
for row in statement:query({3}) do assert(row.v >= 3) end
assert(statement:close())
writable("prepared query can be rebound and reused")

do
    local iter <close> = assert(db:query(sql))
    assert(iter().v)
    assert(db:close())
    assert(iter().v, "closing the DB invalidated its live cursor")
end
writable("scoped cursor releases a zombie connection")
assert(writer:close())
collectgarbage("restart")
collectgarbage("collect")
print("sqlite lifecycle: " .. passed .. " PASS / 0 FAIL")
