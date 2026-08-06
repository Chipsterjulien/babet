-- Babet integration self-test orchestrator.
-- The individual suites live under selftest/suites/.

local Harness = require("selftest.harness")
local suites = require("selftest.suites")

local test = Harness.new({ sandbox = "_babet_selftest" })
test:setup()

for _, module_name in ipairs(suites) do
    test:run(module_name)
end

test:teardown()
test:finish()
