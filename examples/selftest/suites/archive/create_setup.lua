return function(test, context)
    local _ENV = test:environment(context)
    local create_source = root .. "/create-source"
    assert(babet.mkdir(create_source .. "/nested/empty"))
    assert(write_bytes(create_source .. "/alpha.txt", "alpha\n"))
    assert(write_bytes(create_source .. "/nested/binary.bin", "A\0B\255C"))
    assert(write_bytes(create_source .. "/nested/repeated.txt",
        string.rep("compress-me-", 2048)))
    return { create_source = create_source }
end
