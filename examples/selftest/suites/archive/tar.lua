return function(test, context)
    local _ENV = test:environment(context)
    ;(function()
    -- TAR listing and extraction --------------------------------------
    -- ZIP remains handled by miniz. libarchive handles TAR streams with
    -- either no outer compression or the built-in gzip filter. Other filters
    -- remain disabled until their dedicated lots.
    local ustar_long_name = string.rep("p", 120) .. "/" .. string.rep("n", 80)
    local gnu_long_name = string.rep("g", 130) .. "/"
        .. string.rep("h", 130) .. "/file.txt"
    local pax_long_name = string.rep("x", 140) .. "/"
        .. string.rep("y", 140) .. "/data.bin"
    local valid_tar = root .. "/valid-tar.data"
    assert(make_tar(valid_tar, {
        { name = "dir/", typeflag = "5", mode = tonumber("711", 8) },
        {
            name = "dir/hello.txt",
            data = "bonjour\n",
            mode = tonumber("640", 8),
            uid = 123,
            gid = 456,
            mtime = 1750000000,
        },
        { name = "binary.bin", data = "\0A\0B", mode = tonumber("601", 8) },
        { name = "hello-link", typeflag = "2", linkname = "dir/hello.txt",
          mode = tonumber("777", 8) },
        { name = "hello-hardlink", typeflag = "1", linkname = "dir/hello.txt",
          mode = tonumber("644", 8) },
        { name = "named-pipe", typeflag = "6", mode = tonumber("600", 8) },
        { name = "char-device", typeflag = "3", devmajor = 1, devminor = 3,
          mode = tonumber("600", 8) },
        { name = "block-device", typeflag = "4", devmajor = 8, devminor = 0,
          mode = tonumber("600", 8) },
        { name = ustar_long_name, data = "ustar", mode = tonumber("644", 8) },
        { name = gnu_long_name, data = "gnu", gnu_longname = true,
          mode = tonumber("644", 8) },
        { name = pax_long_name, data = "pax", pax_path = true,
          mode = tonumber("644", 8) },
    }))

    local tar_list, tar_list_err = babet.archive.list(valid_tar)
    ok_val("archive.list detects uncompressed TAR by content",
        tar_list, tar_list_err, function(value)
            return value.format == "tar"
                and value.compression == "none"
                and value.count == 11
                and value.total_size == 23
                and value.total_name_bytes == 845
                and value.duplicates == 0
                and value.conflicts == 0
                and value.archive_size == babet.fileSize(valid_tar)
                and value.zip64 == nil
        end)
    ok("archive.list keeps ZIP-only metadata nil for TAR entries",
        tar_list and tar_list.entries[2]
        and tar_list.entries[2].compressed_size == nil
        and tar_list.entries[2].crc32 == nil
        and tar_list.entries[2].compression_method == nil
        and tar_list.entries[2].encrypted == false
        and tar_list.entries[2].supported == true
        and tar_list.entries[2].sparse == false)
    ok("archive.list reports TAR regular-file metadata",
        tar_list and tar_list.entries[2]
        and tar_list.entries[2].name == "dir/hello.txt"
        and tar_list.entries[2].path == "dir/hello.txt"
        and tar_list.entries[2].type == "file"
        and tar_list.entries[2].size == 8
        and tar_list.entries[2].unix_mode == tonumber("640", 8)
        and tar_list.entries[2].index == 2
        and tar_list.entries[2].valid_utf8 == true
        and tar_list.entries[2].mtime == 1750000000
        and tar_list.entries[2].mtime_nsec == 0
        and tar_list.entries[2].uid == 123
        and tar_list.entries[2].gid == 456
        and tar_list.entries[2].duplicate == false
        and tar_list.entries[2].duplicate_of == nil
        and tar_list.entries[2].conflict == false
        and tar_list.entries[2].conflict_with == nil
        and tar_list.entries[2].conflict_reason == nil
        and tar_list.entries[2].safe_path == true
        and tar_list.entries[2].extractable == true
        and tar_list.entries[2].reason == nil)
    ok("archive.list reports TAR symlink target and refusal",
        tar_list and tar_list.entries[4]
        and tar_list.entries[4].type == "symlink"
        and tar_list.entries[4].link_target == "dir/hello.txt"
        and tar_list.entries[4].extractable == false
        and tar_list.entries[4].reason == "symlink entries are refused")
    ok("archive.list reports TAR hard-link target and refusal",
        tar_list and tar_list.entries[5]
        and tar_list.entries[5].type == "hardlink"
        and tar_list.entries[5].link_target == "dir/hello.txt"
        and tar_list.entries[5].extractable == false
        and tar_list.entries[5].reason == "hard link entries are refused")
    ok("archive.list identifies TAR special filesystem types",
        tar_list and tar_list.entries[6].type == "fifo"
        and tar_list.entries[7].type == "character_device"
        and tar_list.entries[8].type == "block_device"
        and tar_list.entries[6].extractable == false
        and tar_list.entries[7].extractable == false
        and tar_list.entries[8].extractable == false)
    ok("archive.list supports ustar prefix paths",
        tar_list and tar_list.entries[9].name == ustar_long_name
        and tar_list.entries[9].safe_path == true)
    ok("archive.list supports GNU TAR long names",
        tar_list and tar_list.entries[10].name == gnu_long_name
        and tar_list.entries[10].size == 3)
    ok("archive.list supports pax path headers",
        tar_list and tar_list.entries[11].name == pax_long_name
        and tar_list.entries[11].size == 3)

    local mixed_tar_test, mixed_tar_test_err = babet.archive.test(valid_tar)
    ok_fail("archive.test rejects a technically valid TAR containing links and special entries",
        mixed_tar_test, mixed_tar_test_err)
    ok("archive.test TAR safety rejection is explicit",
        type(mixed_tar_test_err) == "string"
        and (mixed_tar_test_err:find("symlink", 1, true) ~= nil
            or mixed_tar_test_err:find("link", 1, true) ~= nil),
        "err=" .. tostring(mixed_tar_test_err))

    local safe_tar = root .. "/safe.tar"
    assert(make_tar(safe_tar, {
        { name = "dir/", typeflag = "5", mode = tonumber("2711", 8) },
        { name = "dir/hello.txt", data = "bonjour\n",
          mode = tonumber("4640", 8) },
        { name = "binary.bin", data = "\0A\0B", mode = tonumber("601", 8) },
        { name = "empty.txt", data = "", mode = tonumber("600", 8) },
        { name = "implicit/deep/file.txt", data = "deep",
          mode = tonumber("644", 8) },
    }))
    local safe_tar_list, safe_tar_list_err = babet.archive.list(safe_tar)
    ok_val("archive.list marks safe TAR files and directories extractable",
        safe_tar_list, safe_tar_list_err, function(value)
            return value.format == "tar" and value.count == 5
                and value.entries[1].extractable == true
                and value.entries[2].extractable == true
                and value.entries[1].reason == nil
                and value.entries[2].reason == nil
        end)

    local safe_tar_test, safe_tar_test_err = babet.archive.test(safe_tar)
    ok_val("archive.test fully validates a safe uncompressed TAR",
        safe_tar_test, safe_tar_test_err, function(value)
            return value.format == "tar"
                and value.compression == "none"
                and value.entries == 5
                and value.files == 4
                and value.directories == 1
                and value.total_size == 16
                and value.archive_size == babet.fileSize(safe_tar)
                and value.total_name_bytes == safe_tar_list.total_name_bytes
                and value.zip64 == nil
        end)
    ok("archive.test TAR creates no staging files",
        no_archive_temporaries(root))

    do
        local dry_out = root .. "/tar-dry-run-out"
        local preview, preview_err = babet.archive.extract(
            safe_tar, dry_out, { dry_run = true })
        ok_val("archive.extract TAR dry_run validates without writing",
            preview, preview_err, function(value)
                return value.entries == 5 and value.files == 4
                    and value.directories == 1 and value.skipped == 0
                    and value.bytes == 16 and value.path == dry_out
                    and value.dry_run == true
                    and value.would_create == 5
                    and value.would_overwrite == 0
                    and value.would_skip == 0
                    and value.would_create_destination == true
            end)
        ok("archive.extract TAR dry_run creates no destination or staging files",
            babet.fileExists(dry_out) == false
            and no_archive_temporaries(root))
    end

    local tar_default_out = root .. "/tar-default"
    local tar_default, tar_default_err = babet.archive.extract(
        safe_tar, tar_default_out)
    ok_val("archive.extract extracts an uncompressed TAR",
        tar_default, tar_default_err, function(value)
            return value.entries == 5 and value.files == 4
                and value.directories == 1 and value.skipped == 0
                and value.bytes == 16 and value.path == tar_default_out
        end)
    ok("archive.extract TAR preserves text, binary and empty contents",
        read_bytes(tar_default_out .. "/dir/hello.txt") == "bonjour\n"
        and read_bytes(tar_default_out .. "/binary.bin") == "\0A\0B"
        and read_bytes(tar_default_out .. "/empty.txt") == ""
        and read_bytes(tar_default_out .. "/implicit/deep/file.txt") == "deep")
    ok("archive.extract TAR creates implicit parent directories safely",
        babet.isDir(tar_default_out .. "/implicit") == true
        and babet.isDir(tar_default_out .. "/implicit/deep") == true)
    ok("archive.extract TAR uses safe default permissions",
        babet.getMode(tar_default_out .. "/dir") == tonumber("755", 8)
        and babet.getMode(tar_default_out .. "/dir/hello.txt")
            == tonumber("644", 8))
    ok("archive.extract TAR leaves no staging files",
        no_archive_temporaries(tar_default_out))

    do
        local filter_tar = root .. "/filter-selective.tar"
        assert(make_tar(filter_tar, {
            { name = "src/", typeflag = "5" },
            { name = "src/main.lua", data = "print('ok')\n" },
            { name = "src/generated/", typeflag = "5" },
            { name = "src/generated/cache.tmp", data = "cache" },
            { name = "README.md", data = "readme" },
            { name = "notes.tmp", data = "notes" },
        }))
        local dry_filter_out = root .. "/filter-selective-tar-dry-out"
        local dry_filtered, dry_filtered_err = babet.archive.extract(
            filter_tar, dry_filter_out, {
                dry_run = true,
                include = { "src/**", "README.md" },
                exclude = { "src/generated", "*.tmp", "**/*.tmp" },
            })
        ok_val("archive.extract TAR dry_run applies include/exclude identically",
            dry_filtered, dry_filtered_err, function(value)
                return value.entries == 3 and value.files == 2
                    and value.directories == 1 and value.skipped == 3
                    and value.bytes == 18 and value.dry_run == true
                    and value.would_create == 3
                    and value.would_create_destination == true
            end)
        ok("archive.extract TAR filtered dry_run creates nothing",
            babet.fileExists(dry_filter_out) == false)

        local filter_out = root .. "/filter-selective-tar-out"
        local filtered, filtered_err = babet.archive.extract(
            filter_tar, filter_out, {
                include = { "src/**", "README.md" },
                exclude = { "src/generated", "*.tmp", "**/*.tmp" },
            })
        ok_val("archive.extract TAR applies include/exclude safe globs",
            filtered, filtered_err, function(value)
                return value.entries == 3 and value.files == 2
                    and value.directories == 1 and value.skipped == 3
                    and value.bytes == 18 and value.path == filter_out
            end)
        ok("archive.extract TAR exclude overrides include and prunes subtrees",
            read_bytes(filter_out .. "/src/main.lua") == "print('ok')\n"
            and read_bytes(filter_out .. "/README.md") == "readme"
            and babet.fileExists(filter_out .. "/src/generated") == false
            and babet.fileExists(filter_out .. "/notes.tmp") == false)

        local exclude_only_out = root .. "/filter-exclude-only-tar-out"
        local exclude_only, exclude_only_err = babet.archive.extract(
            filter_tar, exclude_only_out, {
                exclude = { "src/generated", "*.tmp" },
            })
        ok_val("archive.extract TAR supports exclude-only selection",
            exclude_only, exclude_only_err, function(value)
                return value.entries == 3 and value.files == 2
                    and value.directories == 1 and value.skipped == 3
                    and value.bytes == 18
            end)
        ok("archive.extract TAR exclude-only keeps unrelated entries",
            read_bytes(exclude_only_out .. "/src/main.lua") == "print('ok')\n"
            and read_bytes(exclude_only_out .. "/README.md") == "readme"
            and babet.fileExists(exclude_only_out .. "/src/generated") == false
            and babet.fileExists(exclude_only_out .. "/notes.tmp") == false)

        local root_star_out = root .. "/filter-root-star-tar-out"
        local root_star, root_star_err = babet.archive.extract(
            filter_tar, root_star_out, { include = { "*.md" } })
        ok_val("archive.extract TAR keeps '*' component-local",
            root_star, root_star_err, function(value)
                return value.entries == 1 and value.files == 1
                    and value.directories == 0 and value.skipped == 5
            end)
        ok("archive.extract TAR component-local star selects only root README",
            read_bytes(root_star_out .. "/README.md") == "readme"
            and babet.fileExists(root_star_out .. "/src") == false)

        local no_match_out = root .. "/filter-no-match-tar-out"
        local no_match, no_match_err = babet.archive.extract(
            filter_tar, no_match_out, { include = { "missing/**" } })
        ok_val("archive.extract TAR accepts an empty selection",
            no_match, no_match_err, function(value)
                return value.entries == 0 and value.files == 0
                    and value.directories == 0 and value.skipped == 6
                    and value.bytes == 0
            end)
        ok("archive.extract TAR empty selection creates no destination",
            babet.fileExists(no_match_out) == false)

        local special_tar = root .. "/filter-special.tar"
        assert(make_tar(special_tar, {
            { name = "blocked/", typeflag = "5" },
            { name = "blocked/link", typeflag = "2", linkname = "../outside" },
            { name = "safe.txt", data = "safe" },
        }))
        local special_out = root .. "/filter-special-tar-out"
        local special, special_err = babet.archive.extract(
            special_tar, special_out, {
                include = { "**" }, exclude = { "blocked" },
            })
        ok_val("archive.extract TAR ignores excluded special entries",
            special, special_err, function(value)
                return value.entries == 1 and value.files == 1
                    and value.directories == 0 and value.skipped == 2
            end)
        ok("archive.extract TAR excluded directory creates no descendants",
            read_bytes(special_out .. "/safe.txt") == "safe"
            and babet.fileExists(special_out .. "/blocked") == false)

        local escaped_tar = root .. "/filter-escaped.tar"
        assert(make_tar(escaped_tar, {
            { name = "literal*.txt", data = "star" },
            { name = "literalX.txt", data = "x" },
        }))
        local escaped_out = root .. "/filter-escaped-tar-out"
        local escaped, escaped_err = babet.archive.extract(
            escaped_tar, escaped_out, { include = { "literal\\*.txt" } })
        ok_val("archive.extract TAR glob backslash escapes a wildcard",
            escaped, escaped_err, function(value)
                return value.entries == 1 and value.skipped == 1
            end)
        ok("archive.extract TAR escaped star is literal",
            read_bytes(escaped_out .. "/literal*.txt") == "star"
            and babet.fileExists(escaped_out .. "/literalX.txt") == false)

        local worker_out = root .. "/filter-worker-tar-out"
        local worker, worker_err = babet.workers.spawn([[
local result, err = babet.archive.extract(
    worker.args.archive, worker.args.destination,
    { include = { "README.md" } })
if not result then error(err) end
return result
]], { archive = filter_tar, destination = worker_out })
        ok("archive.extract TAR filters start in a worker",
            worker ~= nil and worker_err == nil, tostring(worker_err))
        if worker then
            local joined, value = worker:join()
            ok("archive.extract TAR filters succeed in a worker",
                joined == true and type(value) == "table"
                and value.entries == 1 and value.files == 1
                and value.skipped == 5,
                inspect(value))
            ok("archive.extract TAR filtered worker publishes selected data",
                read_bytes(worker_out .. "/README.md") == "readme")
        end
    end

    local tar_again, tar_again_err = babet.archive.extract(
        safe_tar, tar_default_out)
    ok_fail("archive.extract TAR refuses overwrite by default",
        tar_again, tar_again_err)
    ok("failed TAR overwrite preserves existing contents",
        read_bytes(tar_default_out .. "/dir/hello.txt") == "bonjour\n")

    local tar_preserve_out = root .. "/tar-preserve"
    local tar_preserve, tar_preserve_err = babet.archive.extract(
        safe_tar, tar_preserve_out, { preserve_permissions = true })
    ok_val("archive.extract TAR preserves safe Unix permissions",
        tar_preserve, tar_preserve_err)
    ok("archive.extract TAR strips setuid/setgid bits",
        babet.getMode(tar_preserve_out .. "/dir") == tonumber("711", 8)
        and babet.getMode(tar_preserve_out .. "/dir/hello.txt")
            == tonumber("640", 8)
        and babet.getMode(tar_preserve_out .. "/binary.bin")
            == tonumber("601", 8))

    local tar_replacement = root .. "/tar-replacement.tar"
    assert(make_tar(tar_replacement, {
        { name = "dir/", typeflag = "5" },
        { name = "dir/hello.txt", data = "remplacé\n" },
    }))
    local tar_replaced, tar_replaced_err = babet.archive.extract(
        tar_replacement, tar_default_out, { overwrite = true })
    ok_val("archive.extract TAR overwrite=true publishes atomically",
        tar_replaced, tar_replaced_err, function(value)
            return value.files == 1 and value.directories == 1
                and value.bytes == 10
        end)
    ok("archive.extract TAR overwrite replaces only selected paths",
        read_bytes(tar_default_out .. "/dir/hello.txt") == "remplacé\n"
        and read_bytes(tar_default_out .. "/binary.bin") == "\0A\0B")

    local tar_worker, tar_worker_err = babet.workers.spawn([[
local info, err = babet.archive.list(worker.args.path)
if not info then error(err) end
return {
    format = info.format,
    count = info.count,
    total_size = info.total_size,
    total_name_bytes = info.total_name_bytes,
    duplicates = info.duplicates,
    conflicts = info.conflicts,
    mtime = info.entries[2].mtime,
    uid = info.entries[2].uid,
    gid = info.entries[2].gid,
}
]], { path = valid_tar })
    ok("archive.list TAR starts in a worker",
        tar_worker ~= nil and tar_worker_err == nil, tostring(tar_worker_err))
    if tar_worker then
        local joined, value = tar_worker:join()
        ok("archive.list TAR succeeds in a worker",
            joined == true and type(value) == "table"
            and value.format == "tar" and value.count == 11
            and value.total_size == 23
            and value.total_name_bytes == 845
            and value.duplicates == 0
            and value.conflicts == 0
            and value.mtime == 1750000000
            and value.uid == 123 and value.gid == 456,
            inspect(value))
    end

    local worker_extract_out = root .. "/tar-worker-out"
    local tar_extract_worker, tar_extract_worker_err = babet.workers.spawn([[
local result, err = babet.archive.extract(
    worker.args.archive, worker.args.destination)
if not result then error(err) end
return result
]], { archive = safe_tar, destination = worker_extract_out })
    ok("archive.extract TAR starts in a worker",
        tar_extract_worker ~= nil and tar_extract_worker_err == nil,
        tostring(tar_extract_worker_err))
    if tar_extract_worker then
        local joined, value = tar_extract_worker:join()
        ok("archive.extract TAR succeeds in a worker",
            joined == true and type(value) == "table"
            and value.files == 4 and value.directories == 1
            and value.bytes == 16,
            inspect(value))
        ok("archive.extract TAR worker publishes expected data",
            read_bytes(worker_extract_out .. "/dir/hello.txt") == "bonjour\n")
    end

    local concat_first = root .. "/concat-first.tar"
    local concat_second = root .. "/concat-second.tar"
    local concatenated_tar = root .. "/concatenated.tar"
    assert(make_tar(concat_first, {
        { name = "first.txt", data = "first" },
    }))
    assert(make_tar(concat_second, {
        { name = "second.txt", data = "second" },
    }))
    assert(write_bytes(concatenated_tar,
        assert(read_bytes(concat_first)) .. assert(read_bytes(concat_second))))
    local concatenated_list, concatenated_err =
        babet.archive.list(concatenated_tar)
    ok_val("archive.list inspects concatenated TAR archives",
        concatenated_list, concatenated_err, function(value)
            return value.format == "tar" and value.count == 2
                and value.total_size == 11
                and value.entries[1].name == "first.txt"
                and value.entries[2].name == "second.txt"
        end)
    local concatenated_out = root .. "/concatenated-out"
    local concatenated_extract, concatenated_extract_err =
        babet.archive.extract(concatenated_tar, concatenated_out)
    ok_val("archive.extract traverses concatenated TAR archives",
        concatenated_extract, concatenated_extract_err, function(value)
            return value.files == 2 and value.directories == 0
                and value.bytes == 11
        end)
    ok("archive.extract publishes every concatenated TAR member",
        read_bytes(concatenated_out .. "/first.txt") == "first"
        and read_bytes(concatenated_out .. "/second.txt") == "second")

    local sparse_tar = root .. "/sparse.tar"
    assert(make_old_gnu_sparse_tar(sparse_tar))
    local sparse_tar_list, sparse_tar_list_err = babet.archive.list(sparse_tar)
    ok_val("archive.list identifies an old GNU sparse TAR entry",
        sparse_tar_list, sparse_tar_list_err, function(value)
            return value.format == "tar" and value.count == 1
                and value.total_size == 2048
                and value.entries[1].name == "sparse.bin"
                and value.entries[1].size == 2048
                and value.entries[1].sparse == true
                and value.entries[1].extractable == false
                and value.entries[1].reason == "sparse TAR entries are refused"
        end)
    local sparse_tar_out = root .. "/sparse-tar-out"
    local sparse_tar_extract, sparse_tar_extract_err = babet.archive.extract(
        sparse_tar, sparse_tar_out)
    ok_fail("archive.extract refuses sparse TAR files before writing",
        sparse_tar_extract, sparse_tar_extract_err)
    ok("sparse TAR refusal creates no destination",
        babet.fileExists(sparse_tar_out) == false)

    local compressed_tar = root .. "/empty.tar.gz"
    assert(write_bytes(compressed_tar, string.char(
        31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 99, 96, 24, 5, 163,
        96, 20, 140, 84, 0, 0, 46, 175, 181, 239, 0, 4, 0, 0)))
    local compressed_tar_list, compressed_tar_err =
        babet.archive.list(compressed_tar)
    ok_val("archive.list accepts gzip-compressed TAR by content",
        compressed_tar_list, compressed_tar_err, function(value)
            return value.format == "tar" and value.compression == "gzip"
                and value.count == 0 and value.total_size == 0
                and value.total_name_bytes == 0
                and value.duplicates == 0 and value.conflicts == 0
        end)

    local empty_tar = root .. "/empty.tar"
    assert(write_bytes(empty_tar, string.rep("\0", 1024)))
    local empty_tar_list, empty_tar_err = babet.archive.list(empty_tar)
    ok_val("archive.list accepts a standard empty TAR",
        empty_tar_list, empty_tar_err, function(value)
            return value.format == "tar" and value.count == 0
                and value.total_size == 0 and value.total_name_bytes == 0
                and value.duplicates == 0 and value.conflicts == 0
                and #value.entries == 0
        end)
    local empty_tar_test, empty_tar_test_err = babet.archive.test(empty_tar)
    ok_val("archive.test accepts an empty TAR",
        empty_tar_test, empty_tar_test_err, function(value)
            return value.format == "tar" and value.compression == "none"
                and value.entries == 0 and value.files == 0
                and value.directories == 0 and value.total_size == 0
                and value.total_name_bytes == 0 and value.zip64 == nil
        end)
    local empty_tar_out = root .. "/empty-tar-out"
    local empty_tar_extract, empty_tar_extract_err = babet.archive.extract(
        empty_tar, empty_tar_out)
    ok_val("archive.extract accepts an empty TAR",
        empty_tar_extract, empty_tar_extract_err, function(value)
            return value.files == 0 and value.directories == 0
                and value.bytes == 0
        end)
    ok("archive.extract empty TAR creates the destination root",
        babet.isDir(empty_tar_out) == true)

    local unsafe_tar = root .. "/unsafe.tar"
    assert(make_tar(unsafe_tar, {
        { name = "../escape", data = "1" },
        { name = "/absolute", data = "2" },
        { name = "a\\b", data = "3" },
        { name = "C:/drive", data = "4" },
        { name = "a//b", data = "5" },
        { name = "a/./b", data = "6" },
    }))
    local unsafe_tar_list, unsafe_tar_err = babet.archive.list(unsafe_tar)
    ok_val("archive.list inspects unsafe TAR paths without extracting",
        unsafe_tar_list, unsafe_tar_err,
        function(value) return value.count == 6 end)
    ok("archive.list applies ZIP path policy to TAR entries",
        unsafe_tar_list
        and unsafe_tar_list.entries[1].safe_path == false
        and unsafe_tar_list.entries[2].safe_path == false
        and unsafe_tar_list.entries[3].safe_path == false
        and unsafe_tar_list.entries[4].safe_path == false
        and unsafe_tar_list.entries[5].safe_path == false
        and unsafe_tar_list.entries[6].safe_path == false)
    local unsafe_tar_test, unsafe_tar_test_err = babet.archive.test(unsafe_tar)
    ok_fail("archive.test rejects unsafe TAR paths",
        unsafe_tar_test, unsafe_tar_test_err)
    ok("archive.test unsafe TAR diagnostic is explicit",
        type(unsafe_tar_test_err) == "string"
        and unsafe_tar_test_err:find("cannot be extracted", 1, true) ~= nil,
        "err=" .. tostring(unsafe_tar_test_err))
    local unsafe_tar_out = root .. "/unsafe-tar-out"
    local unsafe_tar_extract, unsafe_tar_extract_err = babet.archive.extract(
        unsafe_tar, unsafe_tar_out)
    ok_fail("archive.extract refuses unsafe TAR paths before writing",
        unsafe_tar_extract, unsafe_tar_extract_err)
    ok("unsafe TAR extraction creates no destination",
        babet.fileExists(unsafe_tar_out) == false)

    local tar_limited, tar_limited_err = babet.archive.list(
        valid_tar, { max_entries = 10 })
    ok_fail("archive.list TAR enforces max_entries",
        tar_limited, tar_limited_err)
    tar_limited, tar_limited_err = babet.archive.list(
        valid_tar, { max_entry_size = 7 })
    ok_fail("archive.list TAR enforces max_entry_size",
        tar_limited, tar_limited_err)
    tar_limited, tar_limited_err = babet.archive.list(
        valid_tar, { max_total_size = 22 })
    ok_fail("archive.list TAR enforces max_total_size",
        tar_limited, tar_limited_err)
    tar_limited, tar_limited_err = babet.archive.list(
        valid_tar, { max_path_length = #pax_long_name - 1 })
    ok_fail("archive.list TAR enforces max_path_length",
        tar_limited, tar_limited_err)
    tar_limited, tar_limited_err = babet.archive.list(
        valid_tar, { max_total_name_bytes = 844 })
    ok_fail("archive.list TAR enforces max_total_name_bytes",
        tar_limited, tar_limited_err)
    local tar_exact, tar_exact_err = babet.archive.list(valid_tar, {
        max_entries = 11,
        max_entry_size = 8,
        max_total_size = 23,
        max_path_length = #pax_long_name,
        max_total_name_bytes = 845,
        max_compression_ratio = 1,
    })
    ok_val("archive.list TAR accepts exact limits",
        tar_exact, tar_exact_err,
        function(value)
            return value.count == 11
                and value.total_size == 23
                and value.total_name_bytes == 845
        end)
    local tar_limited_out = root .. "/tar-limited-out"
    local tar_extract_limited, tar_extract_limited_err = babet.archive.extract(
        safe_tar, tar_limited_out, { max_total_size = 15 })
    ok_fail("archive.extract TAR applies anti-bomb limits before writing",
        tar_extract_limited, tar_extract_limited_err)
    ok("archive.extract TAR limit failure creates no destination",
        babet.fileExists(tar_limited_out) == false)

    local linked_tar = root .. "/valid-tar-link"
    local tar_link_created = babet.exec("ln", { "-s", "valid-tar.data", linked_tar })
    ok("TAR archive symlink fixture created",
        type(tar_link_created) == "table" and tar_link_created.code == 0)
    local linked_tar_list, linked_tar_err = babet.archive.list(linked_tar)
    ok_val("archive.list follows a symlink to a regular TAR",
        linked_tar_list, linked_tar_err,
        function(value) return value.format == "tar" and value.count == 11 end)
    local linked_safe_tar = root .. "/safe-tar-link"
    local linked_safe_created = babet.exec(
        "ln", { "-s", "safe.tar", linked_safe_tar })
    ok("safe TAR archive symlink fixture created",
        type(linked_safe_created) == "table" and linked_safe_created.code == 0)
    local linked_safe_out = root .. "/linked-safe-out"
    local linked_safe_extract, linked_safe_extract_err = babet.archive.extract(
        linked_safe_tar, linked_safe_out)
    ok_val("archive.extract follows a symlink to a regular TAR",
        linked_safe_extract, linked_safe_extract_err,
        function(value) return value.files == 4 and value.bytes == 16 end)
    ok("archive.extract symlinked TAR source content",
        read_bytes(linked_safe_out .. "/binary.bin") == "\0A\0B")

    local duplicate_tar = root .. "/duplicate.tar"
    assert(make_tar(duplicate_tar, {
        { name = "same.txt", data = "first" },
        { name = "same.txt", data = "second" },
    }))
    local duplicate_tar_list, duplicate_tar_list_err =
        babet.archive.list(duplicate_tar)
    ok_val("archive.list reports exact TAR duplicates and output conflicts",
        duplicate_tar_list, duplicate_tar_list_err, function(value)
            return value.duplicates == 1
                and value.conflicts == 1
                and value.entries[1].duplicate == false
                and value.entries[1].conflict == false
                and value.entries[2].duplicate == true
                and value.entries[2].duplicate_of == 1
                and value.entries[2].conflict == true
                and value.entries[2].conflict_with == 1
                and value.entries[2].conflict_reason
                    == "duplicate output path"
        end)
    local duplicate_tar_test, duplicate_tar_test_err =
        babet.archive.test(duplicate_tar)
    ok_fail("archive.test rejects duplicate TAR paths",
        duplicate_tar_test, duplicate_tar_test_err)
    ok("archive.test duplicate TAR diagnostic is explicit",
        type(duplicate_tar_test_err) == "string"
        and duplicate_tar_test_err:find("duplicate output path", 1, true)
            ~= nil,
        "err=" .. tostring(duplicate_tar_test_err))
    local duplicate_tar_out = root .. "/duplicate-tar-out"
    local duplicate_tar_extract, duplicate_tar_extract_err =
        babet.archive.extract(duplicate_tar, duplicate_tar_out)
    ok_fail("archive.extract refuses duplicate TAR output paths",
        duplicate_tar_extract, duplicate_tar_extract_err)
    ok("duplicate TAR refusal creates no destination",
        babet.fileExists(duplicate_tar_out) == false)

    do
        local filtered_duplicate_tar = root .. "/filtered-duplicate.tar"
        assert(make_tar(filtered_duplicate_tar, {
            { name = "same.txt", data = "first" },
            { name = "same.txt", data = "second" },
            { name = "safe.txt", data = "safe" },
        }))
        local filtered_out = root .. "/filtered-duplicate-tar-out"
        local filtered, filtered_err = babet.archive.extract(
            filtered_duplicate_tar, filtered_out,
            { include = { "safe.txt" } })
        ok_val("archive.extract TAR ignores unselected duplicate paths",
            filtered, filtered_err, function(value)
                return value.entries == 1 and value.files == 1
                    and value.skipped == 2 and value.bytes == 4
            end)
        ok("archive.extract TAR unselected duplicates publish only safe data",
            read_bytes(filtered_out .. "/safe.txt") == "safe"
            and babet.fileExists(filtered_out .. "/same.txt") == false)
    end

    local conflict_tar = root .. "/conflict.tar"
    assert(make_tar(conflict_tar, {
        { name = "node", data = "file" },
        { name = "node/child.txt", data = "child" },
    }))
    local conflict_tar_list, conflict_tar_list_err =
        babet.archive.list(conflict_tar)
    ok_val("archive.list reports TAR file/directory conflicts",
        conflict_tar_list, conflict_tar_list_err, function(value)
            return value.duplicates == 0
                and value.conflicts == 1
                and value.entries[2].conflict == true
                and value.entries[2].conflict_with == 1
                and value.entries[2].conflict_reason
                    == "file/directory path conflict"
        end)
    local conflict_tar_out = root .. "/conflict-tar-out"
    local conflict_tar_extract, conflict_tar_extract_err =
        babet.archive.extract(conflict_tar, conflict_tar_out)
    ok_fail("archive.extract refuses TAR file/directory conflicts",
        conflict_tar_extract, conflict_tar_extract_err)
    ok("TAR path-conflict refusal creates no destination",
        babet.fileExists(conflict_tar_out) == false)

    local tar_parent_target = root .. "/tar-parent-target"
    assert(babet.mkdir(tar_parent_target))
    local tar_parent_link = root .. "/tar-parent-link"
    local tar_parent_linked = babet.exec(
        "ln", { "-s", "tar-parent-target", tar_parent_link })
    ok("TAR destination-parent symlink fixture created",
        type(tar_parent_linked) == "table" and tar_parent_linked.code == 0)
    local tar_parent_attack, tar_parent_attack_err = babet.archive.extract(
        safe_tar, tar_parent_link .. "/out")
    ok_fail("archive.extract TAR refuses a symlinked destination parent",
        tar_parent_attack, tar_parent_attack_err)
    do
        local tar_parent_dry, tar_parent_dry_err = babet.archive.extract(
            safe_tar, tar_parent_link .. "/dry-out", { dry_run = true })
        ok_fail("archive.extract TAR dry_run refuses a symlinked destination parent",
            tar_parent_dry, tar_parent_dry_err)
    end
    ok("TAR destination-parent refusal writes nothing through the symlink",
        babet.fileExists(tar_parent_target .. "/out") == false
        and babet.fileExists(tar_parent_target .. "/dry-out") == false)

    local nonregular_payload_tar = root .. "/nonregular-payload.tar"
    assert(make_tar(nonregular_payload_tar, {
        { name = "directory/", typeflag = "5", size = 1, data = "x" },
    }))
    local nonregular_payload_list, nonregular_payload_err =
        babet.archive.list(nonregular_payload_tar)
    ok_fail("archive.list rejects data attached to a non-regular TAR entry",
        nonregular_payload_list, nonregular_payload_err)

    local damaged_tar = root .. "/damaged.tar"
    local valid_tar_bytes = assert(read_bytes(valid_tar))
    assert(write_bytes(damaged_tar, "X" .. valid_tar_bytes:sub(2)))
    local damaged_tar_list, damaged_tar_err = babet.archive.list(damaged_tar)
    ok_fail("archive.list rejects a TAR with an invalid header checksum",
        damaged_tar_list, damaged_tar_err)
    local damaged_tar_test, damaged_tar_test_err = babet.archive.test(damaged_tar)
    ok_fail("archive.test rejects a TAR with an invalid header checksum",
        damaged_tar_test, damaged_tar_test_err)

    local trailing_tar = root .. "/trailing-garbage.tar"
    assert(write_bytes(trailing_tar, valid_tar_bytes .. "NOT-A-TAR"))
    local trailing_tar_list, trailing_tar_err = babet.archive.list(trailing_tar)
    ok_fail("archive.list rejects non-TAR trailing data",
        trailing_tar_list, trailing_tar_err)
    local trailing_tar_test, trailing_tar_test_err = babet.archive.test(trailing_tar)
    ok_fail("archive.test rejects non-TAR trailing data",
        trailing_tar_test, trailing_tar_test_err)

    local truncated_tar = root .. "/truncated.tar"
    assert(make_tar(truncated_tar, {
        { name = "truncated.bin", data = "short", size = 1024 },
    }, { omit_end_blocks = true }))
    local truncated_tar_list, truncated_tar_err = babet.archive.list(truncated_tar)
    ok_fail("archive.list detects truncated TAR entry data",
        truncated_tar_list, truncated_tar_err)
    local truncated_tar_test, truncated_tar_test_err =
        babet.archive.test(truncated_tar)
    ok_fail("archive.test detects truncated TAR entry data",
        truncated_tar_test, truncated_tar_test_err)

    local tar_extract_out = root .. "/tar-special-out"
    local tar_extract, tar_extract_err = babet.archive.extract(
        valid_tar, tar_extract_out)
    ok_fail("archive.extract TAR refuses links and special filesystem types",
        tar_extract, tar_extract_err)
    ok("refused special TAR extraction creates no destination",
        babet.fileExists(tar_extract_out) == false)

    local compressed_tar_out = root .. "/compressed-tar-out"
    local compressed_tar_extract, compressed_tar_extract_err =
        babet.archive.extract(compressed_tar, compressed_tar_out)
    ok_val("archive.extract accepts an empty gzip-compressed TAR",
        compressed_tar_extract, compressed_tar_extract_err,
        function(value)
            return value.files == 0 and value.directories == 0
                and value.bytes == 0
        end)
    ok("empty gzip-compressed TAR creates the destination root",
        babet.isDir(compressed_tar_out) == true)

    local truncated_tar_out = root .. "/truncated-tar-out"
    local truncated_tar_extract, truncated_tar_extract_err =
        babet.archive.extract(truncated_tar, truncated_tar_out)
    ok_fail("archive.extract rejects truncated TAR data before publication",
        truncated_tar_extract, truncated_tar_extract_err)
    ok("truncated TAR extraction creates no destination",
        babet.fileExists(truncated_tar_out) == false)

    local tar_single_path = root .. "/tar-single.txt"
    local tar_single, tar_single_err = babet.archive.extractFile(
        valid_tar, "dir/hello.txt", tar_single_path)
    ok_val("archive.extractFile extracts one TAR entry from a mixed archive",
        tar_single, tar_single_err, function(value)
            return value.bytes == 8 and value.path == tar_single_path
                and value.entry == "dir/hello.txt"
        end)
    ok("archive.extractFile TAR content is binary-safe and independently named",
        read_bytes(tar_single_path) == "bonjour\n"
        and babet.fileExists(root .. "/dir/hello.txt") == false)
    ok("archive.extractFile TAR uses safe default permissions",
        babet.getMode(tar_single_path) == tonumber("644", 8))
    ok("archive.extractFile TAR leaves no staging files",
        no_archive_temporaries(root))

    assert(write_bytes(tar_single_path, "existing"))
    local tar_single_again, tar_single_again_err = babet.archive.extractFile(
        safe_tar, "dir/hello.txt", tar_single_path)
    ok_fail("archive.extractFile TAR refuses overwrite by default",
        tar_single_again, tar_single_again_err)
    ok("failed TAR extractFile preserves the existing destination",
        read_bytes(tar_single_path) == "existing")
    local tar_single_overwrite, tar_single_overwrite_err =
        babet.archive.extractFile(safe_tar, "dir/hello.txt", tar_single_path, {
            overwrite = true,
        })
    ok_val("archive.extractFile TAR overwrite=true",
        tar_single_overwrite, tar_single_overwrite_err,
        function(value) return value.bytes == 8 end)
    ok("archive.extractFile TAR overwrite publishes atomically",
        read_bytes(tar_single_path) == "bonjour\n")

    local tar_single_mode_path = root .. "/tar-single-mode.txt"
    local tar_single_mode, tar_single_mode_err = babet.archive.extractFile(
        safe_tar, "dir/hello.txt", tar_single_mode_path, {
            preserve_permissions = true,
        })
    ok_val("archive.extractFile TAR preserve_permissions",
        tar_single_mode, tar_single_mode_err)
    ok("archive.extractFile TAR preserves only ordinary permission bits",
        babet.getMode(tar_single_mode_path) == tonumber("640", 8))

    local tar_binary_path = root .. "/tar-single-binary.bin"
    local tar_binary, tar_binary_err = babet.archive.extractFile(
        safe_tar, "binary.bin", tar_binary_path)
    ok_val("archive.extractFile TAR extracts binary data",
        tar_binary, tar_binary_err,
        function(value) return value.bytes == 4 end)
    ok("archive.extractFile TAR preserves embedded NUL bytes",
        read_bytes(tar_binary_path) == "\0A\0B")

    local tar_empty_path = root .. "/tar-single-empty.txt"
    local tar_empty_file, tar_empty_file_err = babet.archive.extractFile(
        safe_tar, "empty.txt", tar_empty_path)
    ok_val("archive.extractFile TAR extracts an empty regular file",
        tar_empty_file, tar_empty_file_err,
        function(value) return value.bytes == 0 end)
    ok("archive.extractFile TAR publishes the empty file",
        read_bytes(tar_empty_path) == "")

    local tar_long_path = root .. "/tar-single-long.txt"
    local tar_long, tar_long_err = babet.archive.extractFile(
        valid_tar, pax_long_name, tar_long_path)
    ok_val("archive.extractFile TAR selects the decoded pax pathname",
        tar_long, tar_long_err,
        function(value) return value.entry == pax_long_name and value.bytes == 3 end)
    ok("archive.extractFile TAR pax content",
        read_bytes(tar_long_path) == "pax")

    local tar_missing_path = root .. "/tar-single-missing.txt"
    local tar_missing, tar_missing_err = babet.archive.extractFile(
        safe_tar, "missing.txt", tar_missing_path)
    ok_fail("archive.extractFile TAR reports a missing entry",
        tar_missing, tar_missing_err)
    ok("missing TAR extractFile creates no output",
        babet.fileExists(tar_missing_path) == false)

    local tar_directory_path = root .. "/tar-single-directory"
    local tar_directory, tar_directory_err = babet.archive.extractFile(
        safe_tar, "dir/", tar_directory_path)
    ok_fail("archive.extractFile TAR refuses a directory entry",
        tar_directory, tar_directory_err)
    ok("directory TAR extractFile creates no output",
        babet.fileExists(tar_directory_path) == false)

    local tar_symlink_path = root .. "/tar-single-symlink"
    local tar_symlink, tar_symlink_err = babet.archive.extractFile(
        valid_tar, "hello-link", tar_symlink_path)
    ok_fail("archive.extractFile TAR refuses a symlink entry",
        tar_symlink, tar_symlink_err)
    ok("symlink TAR extractFile creates no output",
        babet.fileExists(tar_symlink_path) == false)

    local tar_duplicate_path = root .. "/tar-single-duplicate.txt"
    local tar_duplicate, tar_duplicate_err = babet.archive.extractFile(
        duplicate_tar, "same.txt", tar_duplicate_path)
    ok_fail("archive.extractFile TAR refuses an ambiguous duplicate name",
        tar_duplicate, tar_duplicate_err)
    ok("ambiguous TAR extractFile creates no output",
        babet.fileExists(tar_duplicate_path) == false)

    local tar_unsafe_path = root .. "/tar-single-unsafe.txt"
    local tar_unsafe, tar_unsafe_err = babet.archive.extractFile(
        unsafe_tar, "../escape", tar_unsafe_path)
    ok_fail("archive.extractFile TAR refuses a selected unsafe path",
        tar_unsafe, tar_unsafe_err)
    ok("unsafe TAR extractFile creates no output",
        babet.fileExists(tar_unsafe_path) == false)

    local mixed_path_tar = root .. "/mixed-path.tar"
    assert(make_tar(mixed_path_tar, {
        { name = "../unsafe.txt", data = "unsafe" },
        { name = "safe.txt", data = "safe" },
    }))
    local mixed_safe_path = root .. "/tar-single-safe.txt"
    local mixed_safe, mixed_safe_err = babet.archive.extractFile(
        mixed_path_tar, "safe.txt", mixed_safe_path)
    ok_val("archive.extractFile TAR may select a safe entry from a mixed archive",
        mixed_safe, mixed_safe_err,
        function(value) return value.bytes == 4 end)
    ok("archive.extractFile TAR mixed-archive content",
        read_bytes(mixed_safe_path) == "safe"
        and babet.fileExists(root .. "/unsafe.txt") == false)

    local mixed_selective_out = root .. "/tar-selective-safe-out"
    local mixed_selective, mixed_selective_err = babet.archive.extract(
        mixed_path_tar, mixed_selective_out, { include = { "safe.txt" } })
    ok_val("archive.extract TAR may select a safe normalized path from a mixed archive",
        mixed_selective, mixed_selective_err, function(value)
            return value.entries == 1 and value.files == 1
                and value.skipped == 1 and value.bytes == 4
        end)
    ok("archive.extract TAR selective mixed-archive extraction stays contained",
        read_bytes(mixed_selective_out .. "/safe.txt") == "safe"
        and babet.fileExists(root .. "/unsafe.txt") == false)

    do
        local mixed_exclude_out = root .. "/tar-exclude-unsafe-out"
        local mixed_exclude, mixed_exclude_err = babet.archive.extract(
            mixed_path_tar, mixed_exclude_out, { exclude = { "../unsafe.txt" } })
        ok_fail("archive.extract TAR exclude-only cannot sanitize an unsafe path",
            mixed_exclude, mixed_exclude_err)
        ok("archive.extract TAR unsafe exclude-only failure creates no destination",
            babet.fileExists(mixed_exclude_out) == false)
    end

    local tar_limited_single_path = root .. "/tar-single-limited.txt"
    local tar_limited_single, tar_limited_single_err = babet.archive.extractFile(
        safe_tar, "empty.txt", tar_limited_single_path, {
            max_total_size = 15,
        })
    ok_fail("archive.extractFile TAR applies limits to the whole archive",
        tar_limited_single, tar_limited_single_err)
    ok("limited TAR extractFile creates no output",
        babet.fileExists(tar_limited_single_path) == false)

    local tar_sparse_path = root .. "/tar-single-sparse.bin"
    local tar_sparse, tar_sparse_err = babet.archive.extractFile(
        sparse_tar, "sparse.bin", tar_sparse_path)
    ok_fail("archive.extractFile TAR refuses a selected sparse file",
        tar_sparse, tar_sparse_err)
    ok("selected sparse TAR extractFile creates no output",
        babet.fileExists(tar_sparse_path) == false)

    local sparse_then_safe_tar = root .. "/sparse-then-safe.tar"
    assert(write_bytes(sparse_then_safe_tar,
        assert(read_bytes(sparse_tar)) .. assert(read_bytes(concat_second))))
    local after_sparse_path = root .. "/tar-single-after-sparse.txt"
    local after_sparse, after_sparse_err = babet.archive.extractFile(
        sparse_then_safe_tar, "second.txt", after_sparse_path)
    ok_val("archive.extractFile TAR skips an unrelated sparse member safely",
        after_sparse, after_sparse_err,
        function(value) return value.bytes == 6 end)
    ok("archive.extractFile TAR reads a selected concatenated member",
        read_bytes(after_sparse_path) == "second")

    local tar_compressed_single_path = root .. "/tar-single-compressed"
    local tar_compressed_single, tar_compressed_single_err =
        babet.archive.extractFile(
            compressed_tar, "anything", tar_compressed_single_path)
    ok_fail("archive.extractFile reports a missing entry in an empty gzip TAR",
        tar_compressed_single, tar_compressed_single_err)
    ok("missing gzip TAR extractFile creates no output",
        babet.fileExists(tar_compressed_single_path) == false)

    local tar_truncated_single_path = root .. "/tar-single-truncated"
    local tar_truncated_single, tar_truncated_single_err =
        babet.archive.extractFile(
            truncated_tar, "truncated.bin", tar_truncated_single_path)
    ok_fail("archive.extractFile rejects truncated TAR before publication",
        tar_truncated_single, tar_truncated_single_err)
    ok("truncated TAR extractFile creates no output",
        babet.fileExists(tar_truncated_single_path) == false)

    local tar_link_single_path = root .. "/tar-single-linked-source.txt"
    local tar_link_single, tar_link_single_err = babet.archive.extractFile(
        linked_safe_tar, "dir/hello.txt", tar_link_single_path)
    ok_val("archive.extractFile follows a symlink to a regular TAR",
        tar_link_single, tar_link_single_err,
        function(value) return value.bytes == 8 end)
    ok("archive.extractFile linked TAR source content",
        read_bytes(tar_link_single_path) == "bonjour\n")

    local tar_single_target = root .. "/tar-single-target.txt"
    assert(write_bytes(tar_single_target, "outside"))
    local tar_single_link = root .. "/tar-single-link.txt"
    local tar_single_linked = babet.exec(
        "ln", { "-s", "tar-single-target.txt", tar_single_link })
    ok("TAR extractFile destination symlink fixture created",
        type(tar_single_linked) == "table" and tar_single_linked.code == 0)
    local tar_link_attack, tar_link_attack_err = babet.archive.extractFile(
        safe_tar, "dir/hello.txt", tar_single_link, { overwrite = true })
    ok_fail("archive.extractFile TAR refuses a symlink destination",
        tar_link_attack, tar_link_attack_err)
    ok("TAR extractFile symlink target remains unchanged",
        read_bytes(tar_single_target) == "outside")

    local tar_extract_file_worker_path = root .. "/tar-single-worker.txt"
    local tar_extract_file_worker, tar_extract_file_worker_err =
        babet.workers.spawn([[
local result, err = babet.archive.extractFile(
    worker.args.archive, worker.args.entry, worker.args.destination)
if not result then error(err) end
return result
]], {
            archive = safe_tar,
            entry = "dir/hello.txt",
            destination = tar_extract_file_worker_path,
        })
    ok("archive.extractFile TAR starts in a worker",
        tar_extract_file_worker ~= nil and tar_extract_file_worker_err == nil,
        tostring(tar_extract_file_worker_err))
    if tar_extract_file_worker then
        local joined, value = tar_extract_file_worker:join()
        ok("archive.extractFile TAR succeeds in a worker",
            joined == true and type(value) == "table"
            and value.bytes == 8 and value.entry == "dir/hello.txt",
            inspect(value))
        ok("archive.extractFile TAR worker publishes expected data",
            read_bytes(tar_extract_file_worker_path) == "bonjour\n")
    end
    end)()
end
