return function(test)
    local _ENV = test:environment()
    test:run("selftest.suites.filesystem.basic")
    test:run("selftest.suites.filesystem.atomic_attributes")
    test:run("selftest.suites.filesystem.find_iterator")
end
