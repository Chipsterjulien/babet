return function(test)
    local _ENV = test:environment()
    test:run("selftest.suites.network.socket")
    test:run("selftest.suites.network.unix_socket")
    test:run("selftest.suites.network.websocket")
    test:run("selftest.suites.network.tls")
end
