return function(test)
    local _ENV = test:environment()
    test:run("selftest.suites.sqlite.connection")
    test:run("selftest.suites.sqlite.exec")
    test:run("selftest.suites.sqlite.query")
    test:run("selftest.suites.sqlite.prepared")
    test:run("selftest.suites.sqlite.backup")
end
