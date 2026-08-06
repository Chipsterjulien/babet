return function(test)
    local _ENV = test:environment()
    test:run("selftest.suites.process.exec")
    test:run("selftest.suites.process.pipeline")
    test:run("selftest.suites.process.spawn_streaming")
end
