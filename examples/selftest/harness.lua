-- Shared harness for the Babet integration self-tests.
-- Each suite receives a private environment: reads fall back to the runtime
-- globals, while an accidental assignment to a new global is rejected.

local Harness = {}
Harness.__index = Harness

local function write_test_file(path, data)
    local file, err = io.open(path, "wb")
    if not file then return nil, err end
    local wrote, write_err = file:write(data)
    local closed, close_err = file:close()
    if not wrote then return nil, write_err end
    if not closed then return nil, close_err end
    return true
end

function Harness.new(options)
    options = options or {}

    local start_dir, start_err = babet.currentDir()
    if not start_dir then
        print("FATAL: currentDir() a échoué: " .. tostring(start_err))
        os.exit(1)
    end

    local self = setmetatable({
        pass = 0,
        fail = 0,
        start_dir = start_dir,
        sandbox = options.sandbox or "_babet_selftest",
    }, Harness)

    self.sb = function(name)
        return self.sandbox .. "/" .. name
    end

    self.ok = function(name, condition, detail)
        if condition then
            self.pass = self.pass + 1
            print("[PASS] " .. name)
        else
            self.fail = self.fail + 1
            print("[FAIL] " .. name
                .. (detail and ("  -> " .. tostring(detail)) or ""))
        end
    end

    self.ok_val = function(name, value, err, validator)
        local good = err == nil and value ~= nil
        if good and validator then good = validator(value) end
        self.ok(name, good,
            "val=" .. tostring(value) .. " err=" .. tostring(err))
    end

    self.ok_act = function(name, result, err)
        self.ok(name, result == true and err == nil,
            "res=" .. tostring(result) .. " err=" .. tostring(err))
    end

    self.ok_fail = function(name, value, err)
        self.ok(name,
            value == nil and type(err) == "string" and #err > 0,
            "val=" .. tostring(value) .. " err=" .. tostring(err))
    end

    self.ok_raises = function(name, fn, needle)
        if type(needle) ~= "string" or #needle == 0 then
            self.ok(name, false,
                "test bug: ok_raises requires a non-empty needle")
            return
        end

        local call_ok, err = pcall(fn)
        local good = call_ok == false and type(err) == "string"
            and err:find(needle, 1, true) ~= nil
        self.ok(name, good, tostring(err))
    end

    self.write_test_file = write_test_file

    self.run_raw_table_access_regressions = function(W)
        do
            local len_calls, index_calls = 0, 0
            local payload = setmetatable({ "alpha", "beta" }, {
                __len = function()
                    len_calls = len_calls + 1
                    error("workers serialization must not invoke __len")
                end,
                __index = function()
                    index_calls = index_calls + 1
                    error("workers serialization must not invoke __index")
                end,
            })
            local call_ok, job, spawn_err = pcall(
                W.spawn,
                "return table.concat(worker.args, ':')",
                payload)
            local joined, value = false, nil
            if call_ok and job then
                joined, value = job:join()
            end
            self.ok("workers serialization ignores __len/__index metamethods",
                call_ok and spawn_err == nil and len_calls == 0
                and index_calls == 0 and joined == true
                and value == "alpha:beta",
                "call_ok=" .. tostring(call_ok)
                .. " spawn_err=" .. tostring(spawn_err)
                .. " len_calls=" .. tostring(len_calls)
                .. " index_calls=" .. tostring(index_calls)
                .. " joined=" .. tostring(joined)
                .. " value=" .. tostring(value))
        end

        do
            local index_calls = 0
            local hostile = {
                __index = function()
                    index_calls = index_calls + 1
                    error("raw sequence access must not invoke __index")
                end,
            }

            local encoded, encode_err = babet.json.encode(
                setmetatable({ "a", "b" }, hostile))
            self.ok("json array serialization uses raw sequence access",
                encoded == '["a","b"]' and encode_err == nil
                and index_calls == 0,
                "encoded=" .. tostring(encoded)
                .. " err=" .. tostring(encode_err)
                .. " index_calls=" .. tostring(index_calls))

            local exec_len_calls = 0
            local exec_hostile = {
                __len = function()
                    exec_len_calls = exec_len_calls + 1
                    error("exec args must not invoke __len")
                end,
                __index = hostile.__index,
            }
            local exec_call_ok, exec_result, exec_err = pcall(
                babet.exec, "printf",
                setmetatable({ "%s", "raw-exec" }, exec_hostile))
            self.ok("exec args ignore __len on dense arrays",
                exec_call_ok and type(exec_result) == "table"
                and exec_err == nil and exec_result.stdout == "raw-exec"
                and exec_len_calls == 0 and index_calls == 0,
                "call_ok=" .. tostring(exec_call_ok)
                .. " err=" .. tostring(exec_err)
                .. " len_calls=" .. tostring(exec_len_calls)
                .. " index_calls=" .. tostring(index_calls))

            local fabricated_index_calls = 0
            local fabricated = setmetatable({ [2] = "raw-exec" }, {
                __len = function() return 2 end,
                __index = function(_, key)
                    fabricated_index_calls = fabricated_index_calls + 1
                    if key == 1 then return "%s" end
                end,
            })
            local fabricated_ok, fabricated_result, fabricated_err = pcall(
                babet.exec, "printf", fabricated)
            self.ok("exec rejects sparse args without invoking __index",
                fabricated_ok and fabricated_result == nil
                and type(fabricated_err) == "string"
                and fabricated_index_calls == 0,
                "call_ok=" .. tostring(fabricated_ok)
                .. " result=" .. tostring(fabricated_result)
                .. " err=" .. tostring(fabricated_err)
                .. " index_calls=" .. tostring(fabricated_index_calls))

            local pipeline_result, pipeline_err = babet.pipeline(
                setmetatable({
                    setmetatable({
                        "printf",
                        setmetatable({ "%s", "raw-pipeline" }, hostile),
                    }, hostile),
                    setmetatable({ "cat" }, hostile),
                }, hostile))
            self.ok("pipeline stages and args use raw sequence access",
                type(pipeline_result) == "table" and pipeline_err == nil
                and pipeline_result.stdout == "raw-pipeline"
                and index_calls == 0,
                "err=" .. tostring(pipeline_err)
                .. " index_calls=" .. tostring(index_calls))
        end
    end

    return self
end

function Harness:environment(context)
    local env = {
        ok = self.ok,
        ok_val = self.ok_val,
        ok_act = self.ok_act,
        ok_fail = self.ok_fail,
        ok_raises = self.ok_raises,
        write_test_file = self.write_test_file,
        run_raw_table_access_regressions =
            self.run_raw_table_access_regressions,
        startDir = self.start_dir,
        SB = self.sandbox,
        sb = self.sb,
        inspect = require("inspect"),
    }

    if context ~= nil then
        for key, value in pairs(context) do
            env[key] = value
        end
    end

    return setmetatable(env, {
        __index = _G,
        __newindex = function(_, key, value)
            if key == "arg" then
                rawset(_G, key, value)
                return
            end
            error("self-test suite attempted to create global '"
                .. tostring(key) .. "'", 2)
        end,
    })
end

function Harness:run(module_name, context)
    local suite = require(module_name)
    if type(suite) ~= "function" then
        error("self-test module '" .. module_name
            .. "' must return a function", 2)
    end
    return suite(self, context)
end

function Harness:setup()
    local cleanup_ok = babet.rmdirAll(self.sandbox)
    if cleanup_ok ~= true then
        babet.remove(self.sandbox)
    end

    print("=== setup ===")
    self.ok_act("mkdir(sandbox)", babet.mkdir(self.sandbox))
end

function Harness:teardown()
    print("")
    print("=== teardown ===")
    self.ok_act("rmdirAll(sandbox)", babet.rmdirAll(self.sandbox))
end

function Harness:finish()
    print("")
    print("==========================================")
    print(string.format("Résultat : %d PASS / %d FAIL",
        self.pass, self.fail))
    print("==========================================")

    if self.fail > 0 then
        os.exit(1)
    end
end

return Harness
