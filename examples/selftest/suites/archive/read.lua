return function(test, context)
    local _ENV = test:environment(context)
    local archive_worker, archive_worker_err = babet.workers.spawn([[
        return type(babet.archive) == "table"
            and type(babet.archive.create) == "function"
            and type(babet.archive.list) == "function"
            and type(babet.archive.test) == "function"
            and type(babet.archive.extract) == "function"
            and type(babet.archive.extractFile) == "function"
            and type(babet.archive.read) == "function"
    ]])
    ok_val("archive submodule registered in worker states",
        archive_worker, archive_worker_err)
    if archive_worker then
        local joined, available = archive_worker:join()
        ok("archive functions available in a worker",
            joined == true and available == true,
            "joined=" .. tostring(joined)
            .. " available=" .. tostring(available))
    end

    ;(function()
    -- Bounded in-memory entry reads ----------------------------------
    local read_function = babet.archive.read
    local function archive_read(...)
        if type(read_function) ~= "function" then
            return nil, "archive.read is not available"
        end
        return read_function(...)
    end

    local manifest = '{"name":"babet"}\n'
    local binary = "\0A\255B\0"
    local read_zip = root .. "/read.zip"
    assert(make_zip(read_zip, {
        { name = "manifest.json", data = manifest },
        { name = "binary.bin", data = binary },
        { name = "../unsafe.txt", data = "unsafe" },
        { name = "folder/" },
        { name = "same.txt", data = "first" },
        { name = "same.txt", data = "second" },
        { name = "\255.bin", data = "raw-name" },
        { name = "empty.bin", data = "" },
        {
            name = "manifest-link",
            data = "manifest.json",
            external_attributes = zip_mode(0xA000, tonumber("777", 8)),
        },
        { name = "encrypted.bin", data = "secret", flags = 1 },
        { name = "unsupported.bin", data = "abc", method = 99 },
    }))

    local named, named_err = archive_read(read_zip, "manifest.json")
    ok_val("archive.read reads a ZIP entry by exact raw name",
        named, named_err, function(value) return value == manifest end)
    local read_contract = table.pack(archive_read(read_zip, "manifest.json", nil))
    ok("archive.read accepts explicit nil options and returns exactly two values",
        read_contract.n == 2 and read_contract[1] == manifest
        and read_contract[2] == nil, inspect(read_contract))

    local indexed, indexed_err = archive_read(read_zip, 2)
    ok_val("archive.read reads a ZIP entry by one-based index",
        indexed, indexed_err, function(value) return value == binary end)
    ok("archive.read returns binary-safe Lua strings",
        indexed == binary and #indexed == #binary)

    local unsafe, unsafe_err = archive_read(read_zip, "../unsafe.txt")
    local read_list, read_list_err = babet.archive.list(read_zip)
    ok_val("archive.read preserves an unsafe raw name without writing",
        unsafe, unsafe_err, function(value) return value == "unsafe" end)
    ok("archive.list keeps the safety indicator for an in-memory read target",
        read_list ~= nil and read_list_err == nil
        and read_list.entries[3].name == "../unsafe.txt"
        and read_list.entries[3].safe_path == false)

    local ambiguous, ambiguous_err = archive_read(read_zip, "same.txt")
    ok_fail("archive.read refuses an ambiguous duplicate raw name",
        ambiguous, ambiguous_err)
    ok("archive.read duplicate diagnostic recommends an index",
        type(ambiguous_err) == "string"
        and ambiguous_err:find("appears more than once", 1, true) ~= nil
        and ambiguous_err:find("index", 1, true) ~= nil,
        "err=" .. tostring(ambiguous_err))
    local first_duplicate, first_duplicate_err = archive_read(read_zip, 5)
    local second_duplicate, second_duplicate_err = archive_read(read_zip, 6)
    ok_val("archive.read index selects the first duplicate explicitly",
        first_duplicate, first_duplicate_err,
        function(value) return value == "first" end)
    ok_val("archive.read index selects the second duplicate explicitly",
        second_duplicate, second_duplicate_err,
        function(value) return value == "second" end)

    local directory, directory_err = archive_read(read_zip, 4)
    ok_fail("archive.read refuses a directory entry",
        directory, directory_err)
    ok("archive.read directory diagnostic is explicit",
        type(directory_err) == "string"
        and directory_err:find("regular file", 1, true) ~= nil,
        "err=" .. tostring(directory_err))
    local missing, missing_err = archive_read(read_zip, "missing.txt")
    ok_fail("archive.read reports a missing raw name", missing, missing_err)
    local zero_index, zero_index_err = archive_read(read_zip, 0)
    ok_fail("archive.read rejects index zero", zero_index, zero_index_err)
    local high_index, high_index_err = archive_read(read_zip, 12)
    ok_fail("archive.read rejects an out-of-range index",
        high_index, high_index_err)
    local raw_name, raw_name_err = archive_read(read_zip, "\255.bin")
    ok_val("archive.read selects an invalid-UTF-8 ZIP name byte for byte",
        raw_name, raw_name_err,
        function(value) return value == "raw-name" end)
    ok("archive.list exposes invalid UTF-8 without rewriting its raw name",
        read_list and read_list.entries[7].name == "\255.bin"
        and read_list.entries[7].valid_utf8 == false)
    local empty_data, empty_data_err = archive_read(read_zip, 8)
    ok("archive.read returns an empty regular ZIP entry",
        empty_data == "" and empty_data_err == nil)
    local zip_link, zip_link_err = archive_read(read_zip, 9)
    ok_fail("archive.read refuses a ZIP symlink entry",
        zip_link, zip_link_err)
    local encrypted, encrypted_err = archive_read(read_zip, 10)
    ok_fail("archive.read refuses an encrypted ZIP entry",
        encrypted, encrypted_err)
    ok("archive.read encrypted ZIP diagnostic is explicit",
        type(encrypted_err) == "string"
        and encrypted_err:find("encrypted", 1, true) ~= nil,
        "err=" .. tostring(encrypted_err))
    local unsupported, unsupported_err = archive_read(read_zip, 11)
    ok_fail("archive.read refuses an unsupported ZIP method",
        unsupported, unsupported_err)
    ok("archive.read unsupported ZIP diagnostic is explicit",
        type(unsupported_err) == "string"
        and unsupported_err:find("not supported", 1, true) ~= nil,
        "err=" .. tostring(unsupported_err))

    local exact, exact_err = archive_read(
        read_zip, "manifest.json", { max_size = #manifest })
    ok_val("archive.read accepts max_size at the exact produced-byte boundary",
        exact, exact_err, function(value) return value == manifest end)
    local limited, limited_err = archive_read(
        read_zip, "manifest.json", { max_size = #manifest - 1 })
    ok_fail("archive.read enforces max_size", limited, limited_err)
    ok("archive.read max_size diagnostic is explicit",
        type(limited_err) == "string"
        and limited_err:find("max_size", 1, true) ~= nil,
        "err=" .. tostring(limited_err))

    local actual_size_zip = root .. "/read-actual-size.zip"
    assert(make_zip(actual_size_zip, {
        {
            name = "expanded.bin",
            data = string.rep("A", 4096),
            payload = deflated_4096_a,
            size = 1,
            local_size = 1,
        },
    }))
    local actual_limited, actual_limited_err = archive_read(
        actual_size_zip, 1, { max_size = 1 })
    ok_fail("archive.read bounds bytes actually produced by ZIP inflation",
        actual_limited, actual_limited_err)
    ok("archive.read actual-output diagnostic names max_size",
        type(actual_limited_err) == "string"
        and actual_limited_err:find("max_size", 1, true) ~= nil,
        "err=" .. tostring(actual_limited_err))

    local whole_limit, whole_limit_err = archive_read(
        read_zip, 1, { max_entries = 5 })
    ok_fail("archive.read applies whole-archive entry limits",
        whole_limit, whole_limit_err)
    local bad_option, bad_option_err = archive_read(
        read_zip, 1, { unknown = true })
    ok_fail("archive.read rejects unknown options", bad_option, bad_option_err)
    local leaked_option, leaked_option_err = babet.archive.list(
        read_zip, { max_size = #manifest })
    ok_fail("archive.list rejects the read-only max_size option",
        leaked_option, leaked_option_err)
    bad_option, bad_option_err = archive_read(
        read_zip, 1, { max_size = 1.0 })
    ok_fail("archive.read max_size must be a strict integer",
        bad_option, bad_option_err)
    bad_option, bad_option_err = archive_read(
        read_zip, 1, { max_size = 0 })
    ok_fail("archive.read rejects max_size zero", bad_option, bad_option_err)
    bad_option, bad_option_err = archive_read(
        read_zip, 1, { max_size = 268435457 })
    ok_fail("archive.read enforces its 256 MiB hard max_size ceiling",
        bad_option, bad_option_err)

    if type(read_function) == "function" then
        ok_raises("archive.read enforces arity",
            function() return read_function(read_zip) end,
            "expects 2 or 3 arguments")
        ok_raises("archive.read rejects excess arguments",
            function() return read_function(read_zip, 1, nil, true) end,
            "expects 2 or 3 arguments")
        ok_raises("archive.read archive path is a strict string",
            function() return read_function(42, 1) end, "string expected")
        ok_raises("archive.read selector must be a string or integer",
            function() return read_function(read_zip, {}) end,
            "string or integer")
        ok_raises("archive.read rejects NUL in the archive path",
            function() return read_function(read_zip .. "\0ignored", 1) end,
            "must not contain NUL byte")
        ok_raises("archive.read rejects NUL in a raw entry name",
            function() return read_function(read_zip, "manifest.json\0") end,
            "must not contain NUL byte")
    else
        ok("archive.read strict argument tests can run", false,
            "archive.read is not available")
    end

    local bad_crc_zip = root .. "/read-bad-crc.zip"
    assert(make_zip(bad_crc_zip, {
        { name = "bad.txt", data = "bad", crc32 = 0 },
    }))
    local bad_crc, bad_crc_err = archive_read(bad_crc_zip, 1)
    ok_fail("archive.read fully verifies the selected ZIP payload",
        bad_crc, bad_crc_err)

    local read_tar = root .. "/read.tar"
    assert(make_tar(read_tar, {
        { name = "manifest.json", data = manifest },
        { name = "binary.bin", data = binary },
        { name = "../unsafe.txt", data = "unsafe" },
        { name = "folder/", typeflag = "5" },
        { name = "same.txt", data = "first" },
        { name = "same.txt", data = "second" },
        { name = "\255.bin", data = "raw-name" },
        { name = "empty.bin", data = "" },
        { name = "manifest-link", typeflag = "2",
          linkname = "manifest.json" },
    }))
    local tar_named, tar_named_err = archive_read(read_tar, "manifest.json")
    ok_val("archive.read reads a TAR entry by exact raw name",
        tar_named, tar_named_err, function(value) return value == manifest end)
    local tar_binary, tar_binary_err = archive_read(read_tar, 2)
    ok_val("archive.read returns binary-safe TAR data by index",
        tar_binary, tar_binary_err, function(value) return value == binary end)
    local tar_ambiguous, tar_ambiguous_err = archive_read(read_tar, "same.txt")
    ok_fail("archive.read refuses an ambiguous TAR raw name",
        tar_ambiguous, tar_ambiguous_err)
    local tar_duplicate, tar_duplicate_err = archive_read(read_tar, 6)
    ok_val("archive.read index disambiguates duplicate TAR entries",
        tar_duplicate, tar_duplicate_err,
        function(value) return value == "second" end)
    local tar_unsafe, tar_unsafe_err = archive_read(read_tar, "../unsafe.txt")
    ok_val("archive.read reads an unsafe TAR name without extracting it",
        tar_unsafe, tar_unsafe_err,
        function(value) return value == "unsafe" end)
    local tar_directory, tar_directory_err = archive_read(read_tar, 4)
    ok_fail("archive.read refuses a TAR directory entry",
        tar_directory, tar_directory_err)
    local tar_raw_name, tar_raw_name_err = archive_read(read_tar, "\255.bin")
    ok_val("archive.read selects an invalid-UTF-8 TAR name byte for byte",
        tar_raw_name, tar_raw_name_err,
        function(value) return value == "raw-name" end)
    local tar_empty, tar_empty_err = archive_read(read_tar, 8)
    ok("archive.read returns an empty regular TAR entry",
        tar_empty == "" and tar_empty_err == nil)
    local tar_link, tar_link_err = archive_read(read_tar, 9)
    ok_fail("archive.read refuses a TAR symlink entry",
        tar_link, tar_link_err)

    for _, format in ipairs({ "gzip", "xz", "bzip2", "zstd" }) do
        local compressed = read_tar .. "." .. format
        local compressed_ok, compressed_err = babet.compression.compress(
            read_tar, compressed, format)
        ok_act("archive.read " .. format .. " TAR fixture is created",
            compressed_ok, compressed_err)
        if compressed_ok then
            local value, value_err = archive_read(compressed, "manifest.json")
            ok_val("archive.read reads a " .. format .. "-compressed TAR",
                value, value_err,
                function(data) return data == manifest end)
        end
    end

    local read_worker, read_worker_err = babet.workers.spawn([[
local data, err = babet.archive.read(worker.args.archive, 2, {
    max_size = worker.args.max_size,
})
if not data then error(err) end
return { size = #data, crc32 = babet.crc32(data) }
]], { archive = read_zip, max_size = #binary })
    ok("archive.read starts safely in a worker",
        read_worker ~= nil and read_worker_err == nil,
        tostring(read_worker_err))
    if read_worker then
        local joined, value = read_worker:join()
        ok("archive.read reads binary data inside a worker",
            joined == true and type(value) == "table"
            and value.size == #binary
            and value.crc32 == babet.crc32(binary), inspect(value))
    end

    ok("archive.read never creates archive staging files",
        no_archive_temporaries(root))
    end)()
end
