local inspect = require("inspect")

local function eq(actual, expected, label)
  if actual ~= expected then
    error((label or "assertion") .. "\nexpected: " .. expected .. "\nactual:   " .. actual, 2)
  end
end

eq(inspect({1, 2, 3}), "{ 1, 2, 3 }", "simple array")
eq(inspect({a = 1, b = {c = 2}}), "{\n  a = 1,\n  b = {\n    c = 2\n  }\n}", "nested table")
eq(inspect("DEL: \127"), '"DEL: \\127"', "DEL escaping")
eq(inspect({["if"] = true, normal = true}), '{\n  ["if"] = true,\n  normal = true\n}', "Lua keyword key")

local a = {1, 2}
local b = {3, a}
a[3] = b
eq(inspect(a), '<1>{ 1, 2, { 3, <table 1> } }', "cycle rendering")

local deep = {}
local cursor = deep
for _ = 1, 20000 do
  local child = {}
  cursor.next = child
  cursor = child
end
eq(inspect(deep, {depth = 2}), "{\n  next = {\n    next = {...}\n  }\n}", "depth-limited deep table")

local mt = {marker = true}
local protected = setmetatable({}, {__metatable = false})
local ok, protected_rendered = pcall(inspect, protected, {process = function(item) return item end})
if not ok then
  error("protected metatable must not raise: " .. tostring(protected_rendered), 2)
end
eq(protected_rendered, "{}", "protected metatable")

local recursive = {1, 2, 3}
recursive.loop = recursive
local ok_process, processed = pcall(inspect, recursive, {process = function(item) return item end})
if not ok_process then
  error("recursive process must not raise: " .. tostring(processed), 2)
end
if not processed:find("<table 1>", 1, true) then
  error("recursive process lost cycle marker: " .. processed, 2)
end

local saved_tostring = _G.tostring
_G.tostring = inspect
local ok_tostring, rendered = pcall(function() return tostring({1, 2, 3}) end)
_G.tostring = saved_tostring
if not ok_tostring then
  error("global tostring override must not raise: " .. tostring(rendered), 2)
end
eq(rendered, "{ 1, 2, 3 }", "global tostring override")

local custom = setmetatable({x = 1}, mt)
local rendered_custom = inspect(custom, {newline = "@", indent = ">>"})
if not rendered_custom:find("@>>x = 1", 1, true) then
  error("custom newline/indent not honored: " .. rendered_custom, 2)
end

print("[PASS] inspect.lua runtime contracts")
