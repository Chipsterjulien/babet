return function(test)
    local _ENV = test:environment()
    test:run("selftest.suites.workers.core")
    test:run("selftest.suites.workers.channels")
    test:run("selftest.suites.workers.pool")
end
