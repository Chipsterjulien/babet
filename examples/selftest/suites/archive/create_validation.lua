return function(test, context)
    local _ENV = test:environment(context)
    local create_source = context.create_source
    local inside, inside_err = babet.archive.create(
        create_source, create_source .. "/inside.zip")
    ok_fail("archive.create refuses an output inside the source",
        inside, inside_err)
    ok("archive.create inside-source refusal leaves no output",
        babet.fileExists(create_source .. "/inside.zip") == false)

    local source_link = root .. "/create-source-link"
    local make_source_link = babet.exec("ln", { "-s", "create-source", source_link })
    ok("archive.create source symlink fixture created",
        type(make_source_link) == "table" and make_source_link.code == 0)
    local linked_source, linked_source_err = babet.archive.create(
        source_link, root .. "/linked-source.zip")
    ok_fail("archive.create refuses a symlink source root",
        linked_source, linked_source_err)

    local entry_link = babet.exec("ln", {
        "-s", "alpha.txt", create_source .. "/entry-link",
    })
    ok("archive.create source-entry symlink fixture created",
        type(entry_link) == "table" and entry_link.code == 0)
    local linked_entry, linked_entry_err = babet.archive.create(
        create_source, root .. "/linked-entry.zip")
    ok_fail("archive.create refuses symlink entries",
        linked_entry, linked_entry_err)
    babet.remove(create_source .. "/entry-link")

    local fifo_created = babet.exec("mkfifo", { create_source .. "/pipe" })
    ok("archive.create FIFO fixture created",
        type(fifo_created) == "table" and fifo_created.code == 0)
    local fifo_archive, fifo_archive_err = babet.archive.create(
        create_source, root .. "/fifo.zip")
    ok_fail("archive.create refuses unsupported filesystem types",
        fifo_archive, fifo_archive_err)
    babet.exec("rm", { "-f", create_source .. "/pipe" })

    assert(write_bytes(create_source .. "/unsafe\\name", "bad"))
    local unsafe_name, unsafe_name_err = babet.archive.create(
        create_source, root .. "/unsafe-name.zip")
    ok_fail("archive.create refuses backslashes in source entry names",
        unsafe_name, unsafe_name_err)
    babet.remove(create_source .. "/unsafe\\name")
    assert(write_bytes(create_source .. "/C:drive", "bad"))
    local drive_name, drive_name_err = babet.archive.create(
        create_source, root .. "/drive-name.zip")
    ok_fail("archive.create refuses drive-prefixed source entry names",
        drive_name, drive_name_err)
    babet.remove(create_source .. "/C:drive")

    local unicode_source = root .. "/unicode-create-source"
    assert(babet.mkdir(unicode_source))
    local unicode_name = "café-雪.txt"
    assert(write_bytes(unicode_source .. "/" .. unicode_name, "unicode"))
    local unicode_zip = root .. "/unicode-create.zip"
    local unicode_created, unicode_created_err = babet.archive.create(
        unicode_source, unicode_zip)
    ok_val("archive.create accepts valid UTF-8 source entry names",
        unicode_created, unicode_created_err)
    local unicode_list, unicode_list_err = babet.archive.list(unicode_zip)
    ok_val("archive.create preserves valid UTF-8 entry names",
        unicode_list, unicode_list_err,
        function(value)
            return value.count == 1 and value.entries[1].name == unicode_name
        end)

    local invalid_utf8_name = "invalid-\255.txt"
    assert(write_bytes(create_source .. "/" .. invalid_utf8_name, "bad"))
    local invalid_utf8_zip = root .. "/invalid-utf8-create.zip"
    local invalid_utf8, invalid_utf8_err = babet.archive.create(
        create_source, invalid_utf8_zip)
    ok_fail("archive.create refuses invalid UTF-8 source entry names",
        invalid_utf8, invalid_utf8_err)
    ok("archive.create invalid UTF-8 diagnostic is explicit",
        type(invalid_utf8_err) == "string"
        and invalid_utf8_err:find("UTF%-8") ~= nil,
        tostring(invalid_utf8_err))
    ok("archive.create invalid UTF-8 failure leaves no output",
        babet.fileExists(invalid_utf8_zip) == false)
    babet.remove(create_source .. "/" .. invalid_utf8_name)

    local deep_source = root .. "/deep-create-source"
    local deep_leaf = deep_source .. string.rep("/d", 257)
    assert(babet.mkdir(deep_leaf))
    local deep_create, deep_create_err = babet.archive.create(
        deep_source, root .. "/deep-create.zip")
    ok_fail("archive.create enforces its internal source-depth limit",
        deep_create, deep_create_err)

    local destination_target = root .. "/destination-target.zip"
    assert(write_bytes(destination_target, "outside"))
    local destination_link = root .. "/destination-link.zip"
    local make_destination_link = babet.exec("ln", {
        "-s", "destination-target.zip", destination_link,
    })
    ok("archive.create destination symlink fixture created",
        type(make_destination_link) == "table" and make_destination_link.code == 0)
    local symlink_destination, symlink_destination_err = babet.archive.create(
        create_source, destination_link, { overwrite = true })
    ok_fail("archive.create refuses a destination symlink",
        symlink_destination, symlink_destination_err)
    ok("archive.create never writes through destination symlinks",
        read_bytes(destination_target) == "outside")

    local parent_target = root .. "/parent-target"
    assert(babet.mkdir(parent_target))
    local parent_link = root .. "/parent-link"
    local make_parent_link = babet.exec("ln", { "-s", "parent-target", parent_link })
    ok("archive.create destination-parent symlink fixture created",
        type(make_parent_link) == "table" and make_parent_link.code == 0)
    local parent_attack, parent_attack_err = babet.archive.create(
        create_source, parent_link .. "/attack.zip")
    ok_fail("archive.create refuses symlinked destination parents",
        parent_attack, parent_attack_err)
    ok("archive.create symlink-parent refusal writes nothing outside",
        babet.fileExists(parent_target .. "/attack.zip") == false)

    local missing_parent, missing_parent_err = babet.archive.create(
        create_source, root .. "/missing-parent/out.zip")
    ok_fail("archive.create requires an existing destination parent",
        missing_parent, missing_parent_err)
    local dotdot_destination, dotdot_destination_err = babet.archive.create(
        create_source, root .. "/sub/../dotdot.zip")
    ok_fail("archive.create rejects '..' in destination parents",
        dotdot_destination, dotdot_destination_err)
    local dotdot_source, dotdot_source_err = babet.archive.create(
        root .. "/other/../create-source", root .. "/dotdot-source.zip")
    ok_fail("archive.create rejects '..' in source paths",
        dotdot_source, dotdot_source_err)
    assert(babet.mkdir(root .. "/destination-directory"))
    local directory_destination, directory_destination_err = babet.archive.create(
        create_source, root .. "/destination-directory", { overwrite = true })
    ok_fail("archive.create refuses a directory destination",
        directory_destination, directory_destination_err)

    local limit, limit_err = babet.archive.create(
        create_source, root .. "/limit-entry.zip", { max_file_size = 4 })
    ok_fail("archive.create enforces max_file_size before writing", limit, limit_err)
    ok("archive.create max_file_size failure leaves no output",
        babet.fileExists(root .. "/limit-entry.zip") == false)
    limit, limit_err = babet.archive.create(
        create_source, root .. "/limit-total.zip", { max_total_size = 5 })
    ok_fail("archive.create enforces max_total_size before writing", limit, limit_err)
    limit, limit_err = babet.archive.create(
        create_source, root .. "/limit-count.zip", { max_entries = 2 })
    ok_fail("archive.create enforces max_entries before writing", limit, limit_err)
    local exact_create_limits, exact_create_limits_err = babet.archive.create(
        create_source, root .. "/exact-create-limits.zip", {
            max_entries = 5,
            max_file_size = #(string.rep("compress-me-", 2048)),
            max_total_size = 6 + 5 + #(string.rep("compress-me-", 2048)),
        })
    ok_val("archive.create size and entry limits are inclusive at the boundary",
        exact_create_limits, exact_create_limits_err)

    local long_destination_name = string.rep("z", 240) .. ".zip"
    local long_destination = root .. "/" .. long_destination_name
    local long_created, long_created_err = babet.archive.create(
        create_source, long_destination)
    ok_val("archive.create supports a valid near-NAME_MAX destination name",
        long_created, long_created_err)
    ok("archive.create near-NAME_MAX output is readable",
        babet.archive.list(long_destination) ~= nil)

    local create_temp_check = babet.exec("find", {
        root, "-maxdepth", "1", "-name", ".babet-create-*", "-print",
    }, { timeout = 5 })
    ok("archive.create leaves no temporary files after success or failure",
        type(create_temp_check) == "table" and create_temp_check.code == 0
        and create_temp_check.stdout == "",
        tostring(create_temp_check and create_temp_check.stdout))

    local nil_options_zip = root .. "/nil-options.zip"
    local nil_options_result = table.pack(
        babet.archive.create(create_source, nil_options_zip, nil))
    ok("archive.create accepts explicit nil options and returns exactly two values",
        nil_options_result.n == 2 and type(nil_options_result[1]) == "table"
        and nil_options_result[2] == nil)
    local list_return_contract = table.pack(babet.archive.list(nil_options_zip, nil))
    ok("archive.list accepts explicit nil options and returns exactly two values",
        list_return_contract.n == 2 and type(list_return_contract[1]) == "table"
        and list_return_contract[2] == nil)
    local test_return_contract = table.pack(babet.archive.test(nil_options_zip, nil))
    ok("archive.test accepts explicit nil options and returns exactly two values",
        test_return_contract.n == 2 and type(test_return_contract[1]) == "table"
        and test_return_contract[2] == nil)

    local create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", "bad")
    ok_fail("archive.create opts must be a table", create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { unknown = true })
    ok_fail("archive.create rejects unknown options", create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { [1] = true })
    ok_fail("archive.create option keys must be strings", create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { format = 42 })
    ok_fail("archive.create format is a strict string",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { format = "rar" })
    ok_fail("archive.create rejects an unknown format",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { format = "tar\0zip" })
    ok_fail("archive.create rejects NUL in format",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { compression_level = 1.0 })
    ok_fail("archive.create compression_level is a strict integer",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { compression_level = -1 })
    ok_fail("archive.create rejects negative compression levels",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { compression_level = 10 })
    ok_fail("archive.create rejects compression levels above 9",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { overwrite = 1 })
    ok_fail("archive.create overwrite is strictly boolean",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { deterministic = 1 })
    ok_fail("archive.create deterministic is strictly boolean",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { include_directories = 1 })
    ok_fail("archive.create include_directories is strictly boolean",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { max_file_size = 1.0 })
    ok_fail("archive.create size limits require strict integers",
        create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { max_file_size = 0 })
    ok_fail("archive.create limits reject zero", create_bad, create_bad_err)
    create_bad, create_bad_err = babet.archive.create(
        create_source, root .. "/bad-create.zip", { max_entries = 100001 })
    ok_fail("archive.create max_entries hard ceiling enforced",
        create_bad, create_bad_err)

    ok_raises("archive.create enforces arity",
        function() return babet.archive.create(create_source) end,
        "expects 2 or 3 arguments")
    ok_raises("archive.create rejects excess arguments",
        function()
            return babet.archive.create(create_source, root .. "/x.zip", nil, true)
        end,
        "expects 2 or 3 arguments")
    ok_raises("archive.create source must be a string or table",
        function() return babet.archive.create(42, root .. "/x.zip") end,
        "directory string or a dense array")
    ok_raises("archive.create destination is a strict string",
        function() return babet.archive.create(create_source, {}) end, "string expected")
    ok_raises("archive.create rejects NUL in source",
        function()
            return babet.archive.create(create_source .. "\0ignored", root .. "/x.zip")
        end,
        "NUL")
    ok_raises("archive.create rejects NUL in destination",
        function()
            return babet.archive.create(create_source, root .. "/x.zip\0ignored")
        end,
        "NUL")
    local empty_source_arg, empty_source_arg_err = babet.archive.create(
        "", root .. "/empty-source-arg.zip")
    ok_fail("archive.create rejects an empty source path",
        empty_source_arg, empty_source_arg_err)
    local empty_destination_arg, empty_destination_arg_err = babet.archive.create(
        create_source, "")
    ok_fail("archive.create rejects an empty destination path",
        empty_destination_arg, empty_destination_arg_err)
    local missing_source, missing_source_err = babet.archive.create(
        root .. "/missing-source", root .. "/missing-source.zip")
    ok_fail("archive.create rejects a missing source directory",
        missing_source, missing_source_err)
    local file_source, file_source_err = babet.archive.create(
        create_source .. "/alpha.txt", root .. "/file-source.zip")
    ok_fail("archive.create rejects a regular-file source",
        file_source, file_source_err)
end
