return function(test)
    local _ENV = test:environment()
    print("")
    print("=== secure archives (ZIP and TAR) ===")

    local context = test:run("selftest.suites.archive.support")
    test:run("selftest.suites.archive.read", context)
    test:run("selftest.suites.archive.tar", context)
    test:run("selftest.suites.archive.zip", context)

    local create_context = test:run(
        "selftest.suites.archive.create_setup", context)
    for key, value in pairs(create_context) do
        context[key] = value
    end

    test:run("selftest.suites.archive.create", context)
    test:run("selftest.suites.archive.create_compressed", context)
    test:run("selftest.suites.archive.create_sources", context)
    test:run("selftest.suites.archive.create_validation", context)

    babet.rmdirAll(context.root)
end
