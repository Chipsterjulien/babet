return function(test, context)
    local _ENV = test:environment(context)
    local empty_zip = root .. "/empty.zip"
    assert(make_zip(empty_zip, {}))
    local empty_list, empty_list_err = babet.archive.list(empty_zip)
    ok_val("archive.list(empty ZIP)", empty_list, empty_list_err,
        function(value)
            return value.format == "zip" and value.compression == "none"
                and value.count == 0 and value.total_size == 0
                and value.total_name_bytes == 0
                and value.duplicates == 0 and value.conflicts == 0
                and #value.entries == 0 and value.zip64 == false
        end)
    do
        local empty_test, empty_test_err = babet.archive.test(empty_zip)
        ok_val("archive.test(empty ZIP)", empty_test, empty_test_err,
            function(value)
                return value.format == "zip" and value.compression == "none"
                    and value.entries == 0 and value.files == 0
                    and value.directories == 0 and value.total_size == 0
                    and value.total_name_bytes == 0 and value.zip64 == false
            end)
    end
    do
        local dry_out = root .. "/empty-dry-run-out"
        local preview, preview_err = babet.archive.extract(
            empty_zip, dry_out, { dry_run = true })
        ok_val("archive.extract dry_run previews an empty ZIP",
            preview, preview_err, function(value)
                return value.entries == 0 and value.files == 0
                    and value.directories == 0 and value.skipped == 0
                    and value.bytes == 0 and value.path == dry_out
                    and value.dry_run == true
                    and value.would_create == 0
                    and value.would_overwrite == 0
                    and value.would_skip == 0
                    and value.would_create_destination == true
            end)
        ok("archive.extract empty ZIP dry_run creates no destination",
            babet.fileExists(dry_out) == false)

        local filtered_out = root .. "/empty-filtered-dry-run-out"
        local filtered, filtered_err = babet.archive.extract(
            empty_zip, filtered_out, {
                dry_run = true,
                include = { "missing/**" },
            })
        ok_val("archive.extract dry_run keeps empty filtered selection inert",
            filtered, filtered_err, function(value)
                return value.entries == 0 and value.skipped == 0
                    and value.dry_run == true
                    and value.would_create_destination == false
            end)
        ok("archive.extract empty filtered dry_run never inspects or creates the destination",
            babet.fileExists(filtered_out) == false)
    end
    local empty_out = root .. "/empty-out"
    local empty_extract, empty_extract_err = babet.archive.extract(
        empty_zip, empty_out)
    ok_val("archive.extract(empty ZIP)", empty_extract, empty_extract_err,
        function(value)
            return value.files == 0 and value.directories == 0
                and value.bytes == 0
        end)
    ok("archive.extract(empty ZIP) creates destination root",
        babet.isDir(empty_out) == true)

    local empty_zip64 = root .. "/empty-zip64.zip"
    assert(make_empty_zip64(empty_zip64))
    local zip64_list, zip64_list_err = babet.archive.list(empty_zip64)
    ok_val("archive.list(empty ZIP64)", zip64_list, zip64_list_err,
        function(value)
            return value.count == 0 and value.total_size == 0
                and value.total_name_bytes == 0
                and value.duplicates == 0 and value.conflicts == 0
                and value.zip64 == true
        end)
    do
        local zip64_test, zip64_test_err = babet.archive.test(empty_zip64)
        ok_val("archive.test(empty ZIP64)", zip64_test, zip64_test_err,
            function(value)
                return value.entries == 0 and value.files == 0
                    and value.directories == 0 and value.total_size == 0
                    and value.zip64 == true
            end)
    end

    do
        local split_zip = root .. "/split-volume.zip"
        assert(write_bytes(split_zip, string.pack(
            "<I4I2I2I2I2I4I4I2",
            0x06054b50, 1, 1, 0, 0, 0, 0, 0)))
        local split_list, split_list_err = babet.archive.list(split_zip)
        ok_fail("archive.list rejects split or multi-volume ZIP metadata",
            split_list, split_list_err)
        ok("split ZIP rejection has an explicit diagnostic",
            type(split_list_err) == "string"
            and split_list_err:find("multi-volume", 1, true) ~= nil,
            "err=" .. tostring(split_list_err))
    end

    do
        local split_count_zip = root .. "/split-count.zip"
        assert(write_bytes(split_count_zip, string.pack(
            "<I4I2I2I2I2I4I4I2",
            0x06054b50, 0, 0, 0, 1, 0, 0, 0)))
        local split_count_list, split_count_err =
            babet.archive.list(split_count_zip)
        ok_fail("archive.list rejects ZIP entries split across disks",
            split_count_list, split_count_err)
        ok("split-entry-count rejection uses the multi-volume diagnostic",
            type(split_count_err) == "string"
            and split_count_err:find("multi-volume", 1, true) ~= nil,
            "err=" .. tostring(split_count_err))
    end

    do
        local split_entry_zip = root .. "/split-entry.zip"
        assert(make_zip(split_entry_zip, {
            { name = "part.txt", data = "x", disk_start = 1 },
        }))
        local split_entry_list, split_entry_err =
            babet.archive.list(split_entry_zip)
        ok_fail("archive.list rejects a ZIP entry stored on another disk",
            split_entry_list, split_entry_err)
        ok("split-entry rejection uses the multi-volume diagnostic",
            type(split_entry_err) == "string"
            and split_entry_err:find("multi-volume", 1, true) ~= nil,
            "err=" .. tostring(split_entry_err))
    end

    do
        local split_zip64_locator = root .. "/split-zip64-locator.zip"
        assert(make_empty_zip64(split_zip64_locator, { locator_disk = 1 }))
        local split_zip64_locator_list, split_zip64_locator_err =
            babet.archive.list(split_zip64_locator)
        ok_fail("archive.list rejects multi-volume ZIP64 locator metadata",
            split_zip64_locator_list, split_zip64_locator_err)
        ok("ZIP64 locator rejection uses the multi-volume diagnostic",
            type(split_zip64_locator_err) == "string"
            and split_zip64_locator_err:find("multi-volume", 1, true) ~= nil,
            "err=" .. tostring(split_zip64_locator_err))
    end

    do
        local split_zip64_eocd = root .. "/split-zip64-eocd.zip"
        assert(make_empty_zip64(split_zip64_eocd, {
            disk_number = 1,
            central_directory_disk = 1,
        }))
        local split_zip64_eocd_list, split_zip64_eocd_err =
            babet.archive.list(split_zip64_eocd)
        ok_fail("archive.list rejects multi-volume ZIP64 EOCD metadata",
            split_zip64_eocd_list, split_zip64_eocd_err)
        ok("ZIP64 EOCD rejection uses the multi-volume diagnostic",
            type(split_zip64_eocd_err) == "string"
            and split_zip64_eocd_err:find("multi-volume", 1, true) ~= nil,
            "err=" .. tostring(split_zip64_eocd_err))
    end

    local valid_zip = root .. "/valid.zip"
    local valid_entries = {
        { name = "dir/", permissions = tonumber("711", 8) },
        { name = "dir/hello.txt", data = "bonjour\n", permissions = tonumber("640", 8) },
        { name = "binary.bin", data = "\0A\0B", permissions = tonumber("701", 8) },
        { name = "empty.txt", data = "", permissions = tonumber("600", 8) },
        {
            name = "compressed.txt",
            data = string.rep("A", 4096),
            payload = deflated_4096_a,
            method = 8,
            permissions = tonumber("600", 8),
        },
    }
    local made, make_err = make_zip(valid_zip, valid_entries)
    ok("archive fixture created", made == true, make_err)

    local truncated_zip = root .. "/truncated-valid.zip"
    local valid_zip_bytes = assert(read_bytes(valid_zip))
    assert(write_bytes(truncated_zip, valid_zip_bytes:sub(1, -11)))
    local truncated_zip_list, truncated_zip_list_err =
        babet.archive.list(truncated_zip)
    ok_fail("archive.list rejects a truncated ZIP central directory",
        truncated_zip_list, truncated_zip_list_err)

    local listed, list_err = babet.archive.list(valid_zip)
    ok_val("archive.list(valid)", listed, list_err, function(value)
        return type(value) == "table"
            and type(value.entries) == "table"
            and value.format == "zip"
            and value.compression == "none"
            and value.count == 5
            and value.total_size == 4108
            and value.total_name_bytes == 50
            and value.duplicates == 0
            and value.conflicts == 0
            and value.archive_size == babet.fileSize(valid_zip)
            and value.zip64 == false
    end)
    ok("archive.list directory metadata",
        listed and listed.entries[1]
        and listed.entries[1].name == "dir/"
        and listed.entries[1].path == "dir"
        and listed.entries[1].type == "directory"
        and listed.entries[1].size == 0
        and listed.entries[1].safe_path == true
        and listed.entries[1].extractable == true
        and listed.entries[1].reason == nil
        and listed.entries[1].unix_mode == tonumber("711", 8))
    ok("archive.list regular-file metadata",
        listed and listed.entries[2]
        and listed.entries[2].name == "dir/hello.txt"
        and listed.entries[2].type == "file"
        and listed.entries[2].size == 8
        and listed.entries[2].compressed_size == 8
        and listed.entries[2].crc32 == crc32_number("bonjour\n")
        and listed.entries[2].compression_method == 0
        and listed.entries[2].index == 2
        and listed.entries[2].valid_utf8 == true
        and math.type(listed.entries[2].mtime) == "integer"
        and listed.entries[2].mtime_nsec == nil
        and listed.entries[2].uid == nil
        and listed.entries[2].gid == nil
        and listed.entries[2].duplicate == false
        and listed.entries[2].duplicate_of == nil
        and listed.entries[2].conflict == false
        and listed.entries[2].conflict_with == nil
        and listed.entries[2].conflict_reason == nil
        and listed.entries[2].encrypted == false
        and listed.entries[2].supported == true
        and listed.entries[2].unix_mode == tonumber("640", 8))
    ok("archive.list DEFLATE metadata",
        listed and listed.entries[5]
        and listed.entries[5].size == 4096
        and listed.entries[5].compressed_size == #deflated_4096_a
        and listed.entries[5].compression_method == 8
        and listed.entries[5].extractable == true)

    do
        local tested, test_err = babet.archive.test(valid_zip)
        ok_val("archive.test fully reads and validates every ZIP payload",
            tested, test_err, function(value)
                return value.format == "zip"
                    and value.compression == "none"
                    and value.entries == 5
                    and value.files == 4
                    and value.directories == 1
                    and value.total_size == 4108
                    and value.archive_size == babet.fileSize(valid_zip)
                    and value.total_name_bytes == 50
                    and value.zip64 == false
            end)
    end
    ok("archive.test ZIP creates no staging files",
        no_archive_temporaries(root))

    do
        local dry_out = root .. "/zip-dry-run-out"
        local preview, preview_err = babet.archive.extract(
            valid_zip, dry_out, { dry_run = true })
        ok_val("archive.extract ZIP dry_run validates selected payloads without writing",
            preview, preview_err, function(value)
                return value.entries == 5 and value.files == 4
                    and value.directories == 1 and value.skipped == 0
                    and value.bytes == 4108 and value.path == dry_out
                    and value.dry_run == true
                    and value.would_create == 5
                    and value.would_overwrite == 0
                    and value.would_skip == 0
                    and value.would_create_destination == true
            end)
        ok("archive.extract ZIP dry_run leaves no filesystem trace",
            babet.fileExists(dry_out) == false
            and no_archive_temporaries(root))

        local worker_out = root .. "/zip-dry-run-worker-out"
        local worker, worker_err = babet.workers.spawn([[
local result, err = babet.archive.extract(
    worker.args.archive, worker.args.destination,
    { dry_run = true, include = { "dir/**" } })
if not result then error(err) end
return result
]], { archive = valid_zip, destination = worker_out })
        ok("archive.extract dry_run starts in a worker",
            worker ~= nil and worker_err == nil, tostring(worker_err))
        if worker then
            local joined, value = worker:join()
            ok("archive.extract dry_run succeeds in a worker",
                joined == true and type(value) == "table"
                and value.dry_run == true and value.entries == 2
                and value.files == 1 and value.directories == 1
                and value.skipped == 3 and value.would_create == 2
                and value.would_create_destination == true,
                inspect(value))
            ok("archive.extract worker dry_run creates no destination",
                babet.fileExists(worker_out) == false)
        end
    end

    do
        local descriptor_data = "descriptor-data"
        local descriptor_crc = crc32_number(descriptor_data)
        local descriptor_zip = root .. "/descriptor.zip"
        assert(make_zip(descriptor_zip, {
            {
                name = "descriptor.txt",
                data = descriptor_data,
                flags = 0x0008,
                local_crc32 = 0,
                local_compressed_size = 0,
                local_size = 0,
                descriptor = string.pack("<I4I4I4I4", 0x08074b50,
                    descriptor_crc, #descriptor_data, #descriptor_data),
            },
        }))
        local descriptor_test, descriptor_test_err =
            babet.archive.test(descriptor_zip)
        ok_val("archive.test validates signed ZIP data descriptors",
            descriptor_test, descriptor_test_err,
            function(value)
                return value.entries == 1 and value.files == 1
                    and value.total_size == #descriptor_data
            end)

        local unsigned_descriptor_zip = root .. "/unsigned-descriptor.zip"
        assert(make_zip(unsigned_descriptor_zip, {
            {
                name = "unsigned.txt",
                data = descriptor_data,
                flags = 0x0008,
                local_crc32 = 0,
                local_compressed_size = 0,
                local_size = 0,
                descriptor = string.pack("<I4I4I4", descriptor_crc,
                    #descriptor_data, #descriptor_data),
            },
        }))
        local unsigned_test, unsigned_test_err =
            babet.archive.test(unsigned_descriptor_zip)
        ok_val("archive.test validates unsigned ZIP data descriptors",
            unsigned_test, unsigned_test_err,
            function(value)
                return value.entries == 1 and value.files == 1
                    and value.total_size == #descriptor_data
            end)
    end

    do
        local bad_local_signature = root .. "/bad-local-signature.zip"
        assert(make_zip(bad_local_signature, {
            { name = "empty.txt", data = "", local_signature = 0x04034b51 },
        }))
        local listed, listed_err = babet.archive.list(bad_local_signature)
        ok_val("archive.list remains a metadata-only scan for local ZIP damage",
            listed, listed_err)
        local tested, tested_err = babet.archive.test(bad_local_signature)
        ok_fail("archive.test rejects a damaged ZIP local-header signature",
            tested, tested_err)
        ok("damaged local-header diagnostic is explicit",
            type(tested_err) == "string"
            and tested_err:find("local-header", 1, true) ~= nil,
            "err=" .. tostring(tested_err))
    end

    do
        local bad_local_name = root .. "/bad-local-name.zip"
        assert(make_zip(bad_local_name, {
            { name = "safe.txt", local_name = "evil.txt", data = "safe" },
        }))
        local tested, tested_err = babet.archive.test(bad_local_name)
        ok_fail("archive.test rejects differing local and central ZIP names",
            tested, tested_err)
        ok("local-name mismatch diagnostic is explicit",
            type(tested_err) == "string"
            and tested_err:find("local filename", 1, true) ~= nil,
            "err=" .. tostring(tested_err))
    end

    do
        local bad_empty_metadata = root .. "/bad-empty-metadata.zip"
        assert(make_zip(bad_empty_metadata, {
            { name = "empty.txt", data = "", local_crc32 = 1 },
        }))
        local tested, tested_err = babet.archive.test(bad_empty_metadata)
        ok_fail("archive.test validates local metadata for empty ZIP files",
            tested, tested_err)
    end

    do
        local directory_data_zip = root .. "/directory-data.zip"
        assert(make_zip(directory_data_zip, {
            { name = "folder/", data = "unexpected" },
        }))
        local tested, tested_err = babet.archive.test(directory_data_zip)
        ok_fail("archive.test rejects ZIP directory entries containing data",
            tested, tested_err)
    end
    do
        local test_worker, test_worker_err = babet.workers.spawn([[
local result, err = babet.archive.test(worker.args.archive)
if not result then error(err) end
return result
]], { archive = valid_zip })
        ok("archive.test starts in a worker",
            test_worker ~= nil and test_worker_err == nil,
            tostring(test_worker_err))
        if test_worker then
            local joined, value = test_worker:join()
            ok("archive.test succeeds in a worker",
                joined == true and type(value) == "table"
                and value.format == "zip" and value.entries == 5
                and value.files == 4 and value.total_size == 4108,
                inspect(value))
        end
    end

    -- Les noms temporaires internes ne doivent jamais entrer en conflit avec
    -- un nom de sortie contrôlé par l'archive. Le compteur vaut encore zéro :
    -- les extractions précédentes ne contenaient aucun fichier.
    local proc_stat = read_bytes("/proc/self/stat")
    local self_pid = proc_stat and proc_stat:match("^(%d+)")
    ok("archive temporary collision fixture can identify current PID",
        self_pid ~= nil)
    if self_pid then
        local temp_prefix = ".babet-archive-" .. self_pid .. "-"
        local collision_zip = root .. "/temporary-name-collision.zip"
        assert(make_zip(collision_zip, {
            { name = temp_prefix .. "1", data = "first" },
            { name = temp_prefix .. "0", data = "second" },
        }))
        local collision_out = root .. "/temporary-name-collision-out"
        local collision_result, collision_err = babet.archive.extract(
            collision_zip, collision_out)
        ok_val("archive staging names never collide with archive outputs",
            collision_result, collision_err,
            function(value) return value.files == 2 end)
        local collision_files = babet.listFiles(collision_out) or {}
        local collision_seen = {}
        for _, name in ipairs(collision_files) do collision_seen[name] = true end
        ok("archive output names resembling staging files are preserved",
            read_bytes(collision_out .. "/" .. temp_prefix .. "1") == "first"
            and read_bytes(collision_out .. "/" .. temp_prefix .. "0") == "second"
            and #collision_files == 2
            and collision_seen[temp_prefix .. "1"] == true
            and collision_seen[temp_prefix .. "0"] == true)
    end

    local extract_dir = root .. "/extract-default"
    local extracted, extract_err = babet.archive.extract(valid_zip, extract_dir)
    ok_val("archive.extract(valid)", extracted, extract_err, function(value)
        return value.entries == 5 and value.files == 4
            and value.directories == 1 and value.skipped == 0
            and value.bytes == 4108 and value.path == extract_dir
            and value.dry_run == nil
    end)
    ok("archive.extract text content",
        read_bytes(extract_dir .. "/dir/hello.txt") == "bonjour\n")
    ok("archive.extract binary and NUL content",
        read_bytes(extract_dir .. "/binary.bin") == "\0A\0B")
    ok("archive.extract empty file",
        read_bytes(extract_dir .. "/empty.txt") == "")
    ok("archive.extract DEFLATE content",
        read_bytes(extract_dir .. "/compressed.txt") == string.rep("A", 4096))
    local default_file_mode = babet.getMode(extract_dir .. "/binary.bin")
    local default_dir_mode = babet.getMode(extract_dir .. "/dir")
    ok("archive.extract uses safe default file mode",
        default_file_mode == tonumber("644", 8), tostring(default_file_mode))
    ok("archive.extract uses safe default directory mode",
        default_dir_mode == tonumber("755", 8), tostring(default_dir_mode))
    ok("archive.extract leaves no staging files",
        no_archive_temporaries(extract_dir))

    do
        local mixed_destination = root .. "/dry-run-mixed-destination"
        assert(babet.mkdir(mixed_destination .. "/dir"))
        assert(write_bytes(mixed_destination .. "/dir/hello.txt", "old\n"))
        local mixed, mixed_err = babet.archive.extract(
            valid_zip, mixed_destination, {
                dry_run = true,
                overwrite = true,
            })
        ok_val("archive.extract dry_run classifies create overwrite and skip",
            mixed, mixed_err, function(value)
                return value.entries == 5 and value.files == 4
                    and value.directories == 1
                    and value.would_create == 3
                    and value.would_overwrite == 1
                    and value.would_skip == 1
                    and value.would_create_destination == false
                    and value.would_create + value.would_overwrite
                        + value.would_skip == value.entries
            end)
        ok("archive.extract mixed dry_run performs no planned action",
            read_bytes(mixed_destination .. "/dir/hello.txt") == "old\n"
            and babet.fileExists(mixed_destination .. "/binary.bin") == false
            and babet.fileExists(mixed_destination .. "/empty.txt") == false
            and babet.fileExists(mixed_destination .. "/compressed.txt") == false
            and no_archive_temporaries(mixed_destination))
    end

    do
        local before_hello = read_bytes(extract_dir .. "/dir/hello.txt")
        local before_binary = read_bytes(extract_dir .. "/binary.bin")
        local before_file_mode = babet.getMode(extract_dir .. "/binary.bin")
        local before_dir_mode = babet.getMode(extract_dir .. "/dir")
        local preview, preview_err = babet.archive.extract(
            valid_zip, extract_dir, {
                dry_run = true,
                overwrite = true,
                preserve_permissions = true,
            })
        ok_val("archive.extract dry_run reports existing destination actions",
            preview, preview_err, function(value)
                return value.entries == 5 and value.files == 4
                    and value.directories == 1 and value.skipped == 0
                    and value.dry_run == true
                    and value.would_create == 0
                    and value.would_overwrite == 4
                    and value.would_skip == 1
                    and value.would_create_destination == false
                    and value.would_create + value.would_overwrite
                        + value.would_skip == value.entries
            end)
        ok("archive.extract dry_run never changes existing bytes or modes",
            read_bytes(extract_dir .. "/dir/hello.txt") == before_hello
            and read_bytes(extract_dir .. "/binary.bin") == before_binary
            and babet.getMode(extract_dir .. "/binary.bin") == before_file_mode
            and babet.getMode(extract_dir .. "/dir") == before_dir_mode
            and no_archive_temporaries(extract_dir))

        local refused, refused_err = babet.archive.extract(
            valid_zip, extract_dir, { dry_run = true })
        ok_fail("archive.extract dry_run preserves overwrite=false refusal",
            refused, refused_err)
        ok("archive.extract refused dry_run leaves existing files intact",
            read_bytes(extract_dir .. "/dir/hello.txt") == before_hello
            and read_bytes(extract_dir .. "/binary.bin") == before_binary)
    end

    do
        local filter_zip = root .. "/filter-selective.zip"
        assert(make_zip(filter_zip, {
            { name = "src/" },
            { name = "src/main.lua", data = "print('ok')\n" },
            { name = "src/generated/" },
            { name = "src/generated/cache.tmp", data = "cache" },
            { name = "README.md", data = "readme" },
            { name = "notes.tmp", data = "notes" },
        }))
        local dry_filter_out = root .. "/filter-selective-zip-dry-out"
        local dry_filtered, dry_filtered_err = babet.archive.extract(
            filter_zip, dry_filter_out, {
                dry_run = true,
                include = { "src/**", "README.md" },
                exclude = { "src/generated", "*.tmp", "**/*.tmp" },
            })
        ok_val("archive.extract ZIP dry_run applies include/exclude identically",
            dry_filtered, dry_filtered_err, function(value)
                return value.entries == 3 and value.files == 2
                    and value.directories == 1 and value.skipped == 3
                    and value.bytes == 18 and value.dry_run == true
                    and value.would_create == 3
                    and value.would_overwrite == 0
                    and value.would_skip == 0
                    and value.would_create_destination == true
            end)
        ok("archive.extract ZIP filtered dry_run creates nothing",
            babet.fileExists(dry_filter_out) == false)

        local filter_out = root .. "/filter-selective-zip-out"
        local filtered, filtered_err = babet.archive.extract(
            filter_zip, filter_out, {
                include = { "src/**", "README.md" },
                exclude = { "src/generated", "*.tmp", "**/*.tmp" },
            })
        ok_val("archive.extract ZIP applies include/exclude safe globs",
            filtered, filtered_err, function(value)
                return value.entries == 3 and value.files == 2
                    and value.directories == 1 and value.skipped == 3
                    and value.bytes == 18 and value.path == filter_out
            end)
        ok("archive.extract ZIP exclude overrides include and prunes subtrees",
            read_bytes(filter_out .. "/src/main.lua") == "print('ok')\n"
            and read_bytes(filter_out .. "/README.md") == "readme"
            and babet.fileExists(filter_out .. "/src/generated") == false
            and babet.fileExists(filter_out .. "/notes.tmp") == false)

        local exclude_only_out = root .. "/filter-exclude-only-zip-out"
        local exclude_only, exclude_only_err = babet.archive.extract(
            filter_zip, exclude_only_out, {
                exclude = { "src/generated", "*.tmp" },
            })
        ok_val("archive.extract ZIP supports exclude-only selection",
            exclude_only, exclude_only_err, function(value)
                return value.entries == 3 and value.files == 2
                    and value.directories == 1 and value.skipped == 3
                    and value.bytes == 18
            end)
        ok("archive.extract ZIP exclude-only keeps unrelated entries",
            read_bytes(exclude_only_out .. "/src/main.lua") == "print('ok')\n"
            and read_bytes(exclude_only_out .. "/README.md") == "readme"
            and babet.fileExists(exclude_only_out .. "/src/generated") == false
            and babet.fileExists(exclude_only_out .. "/notes.tmp") == false)

        local question_out = root .. "/filter-question-zip-out"
        local question, question_err = babet.archive.extract(
            filter_zip, question_out, { include = { "src/main.lu?" } })
        ok_val("archive.extract ZIP '?' matches exactly one non-slash byte",
            question, question_err, function(value)
                return value.entries == 1 and value.files == 1
                    and value.skipped == 5
            end)
        ok("archive.extract ZIP '?' selected the expected file",
            read_bytes(question_out .. "/src/main.lua") == "print('ok')\n")

        local case_out = root .. "/filter-case-zip-out"
        local case_result, case_err = babet.archive.extract(
            filter_zip, case_out, { include = { "readme.md" } })
        ok_val("archive.extract ZIP safe globs are case-sensitive",
            case_result, case_err, function(value)
                return value.entries == 0 and value.skipped == 6
            end)
        ok("archive.extract ZIP case mismatch creates no destination",
            babet.fileExists(case_out) == false)

        local empty_filters_out = root .. "/filter-empty-arrays-zip-out"
        local empty_filters, empty_filters_err = babet.archive.extract(
            filter_zip, empty_filters_out, { include = {}, exclude = {} })
        ok_val("archive.extract ZIP empty filter arrays are historical no-ops",
            empty_filters, empty_filters_err, function(value)
                return value.entries == 6 and value.files == 4
                    and value.directories == 2 and value.skipped == 0
            end)
        ok("archive.extract ZIP empty filter arrays extract every entry",
            read_bytes(empty_filters_out .. "/README.md") == "readme"
            and read_bytes(empty_filters_out .. "/src/generated/cache.tmp") == "cache"
            and read_bytes(empty_filters_out .. "/notes.tmp") == "notes")

        local existing_out = root .. "/filter-existing-zip-out"
        assert(babet.mkdir(existing_out .. "/src/generated"))
        assert(write_bytes(existing_out .. "/src/generated/cache.tmp", "keep"))
        local existing, existing_err = babet.archive.extract(
            filter_zip, existing_out, { include = { "README.md" } })
        ok_val("archive.extract ZIP ignores destination collisions outside selection",
            existing, existing_err, function(value)
                return value.entries == 1 and value.skipped == 5
            end)
        ok("archive.extract ZIP leaves unselected existing paths untouched",
            read_bytes(existing_out .. "/README.md") == "readme"
            and read_bytes(existing_out .. "/src/generated/cache.tmp") == "keep")

        local no_match_out = root .. "/filter-no-match-zip-out"
        local no_match, no_match_err = babet.archive.extract(
            filter_zip, no_match_out, { include = { "missing/**" } })
        ok_val("archive.extract ZIP accepts an empty selection",
            no_match, no_match_err, function(value)
                return value.entries == 0 and value.files == 0
                    and value.directories == 0 and value.skipped == 6
                    and value.bytes == 0
            end)
        ok("archive.extract ZIP empty selection creates no destination",
            babet.fileExists(no_match_out) == false)

        local symlink_external = zip_mode(0xA000, tonumber("777", 8))
        local special_zip = root .. "/filter-special.zip"
        assert(make_zip(special_zip, {
            { name = "blocked/" },
            { name = "blocked/link", data = "../outside",
              external_attributes = symlink_external },
            { name = "safe.txt", data = "safe" },
        }))
        local special_out = root .. "/filter-special-zip-out"
        local special, special_err = babet.archive.extract(
            special_zip, special_out, {
                include = { "**" }, exclude = { "blocked" },
            })
        ok_val("archive.extract ZIP ignores excluded special entries",
            special, special_err, function(value)
                return value.entries == 1 and value.files == 1
                    and value.directories == 0 and value.skipped == 2
            end)
        ok("archive.extract ZIP excluded directory creates no descendants",
            read_bytes(special_out .. "/safe.txt") == "safe"
            and babet.fileExists(special_out .. "/blocked") == false)

        local worker_out = root .. "/filter-worker-zip-out"
        local worker, worker_err = babet.workers.spawn([[
local result, err = babet.archive.extract(
    worker.args.archive, worker.args.destination,
    { include = { "README.md" } })
if not result then error(err) end
return result
]], { archive = filter_zip, destination = worker_out })
        ok("archive.extract ZIP filters start in a worker",
            worker ~= nil and worker_err == nil, tostring(worker_err))
        if worker then
            local joined, value = worker:join()
            ok("archive.extract ZIP filters succeed in a worker",
                joined == true and type(value) == "table"
                and value.entries == 1 and value.files == 1
                and value.skipped == 5,
                inspect(value))
            ok("archive.extract ZIP filtered worker publishes selected data",
                read_bytes(worker_out .. "/README.md") == "readme")
        end
    end

    local refused, refused_err = babet.archive.extract(valid_zip, extract_dir)
    ok_fail("archive.extract refuses overwrite by default", refused, refused_err)
    ok("archive.extract failed overwrite preserves content",
        read_bytes(extract_dir .. "/dir/hello.txt") == "bonjour\n")

    local replacement_zip = root .. "/replacement.zip"
    assert(make_zip(replacement_zip, {
        { name = "dir/" },
        { name = "dir/hello.txt", data = "remplacé\n" },
    }))
    local replaced, replaced_err = babet.archive.extract(
        replacement_zip, extract_dir, { overwrite = true })
    ok_val("archive.extract overwrite=true", replaced, replaced_err,
        function(value) return value.files == 1 and value.directories == 1 end)
    ok("archive.extract overwrite replaces atomically",
        read_bytes(extract_dir .. "/dir/hello.txt") == "remplacé\n")

    local preserve_dir = root .. "/extract-preserve"
    local preserved, preserved_err = babet.archive.extract(
        valid_zip, preserve_dir, { preserve_permissions = true })
    ok_val("archive.extract preserve_permissions", preserved, preserved_err)
    local preserved_file_mode = babet.getMode(preserve_dir .. "/binary.bin")
    local preserved_dir_mode = babet.getMode(preserve_dir .. "/dir")
    ok("archive.extract preserves regular permissions",
        preserved_file_mode == tonumber("701", 8), tostring(preserved_file_mode))
    ok("archive.extract preserves directory permissions",
        preserved_dir_mode == tonumber("711", 8), tostring(preserved_dir_mode))

    local special_zip = root .. "/special-modes.zip"
    assert(make_zip(special_zip, {
        { name = "special/", permissions = tonumber("2777", 8) },
        { name = "special/tool", data = "x", permissions = tonumber("4755", 8) },
    }))
    local special_dir = root .. "/special-modes"
    local special_result, special_err = babet.archive.extract(
        special_zip, special_dir, { preserve_permissions = true })
    ok_val("archive.extract strips special permission bits", special_result, special_err)
    ok("archive directory setgid bit stripped",
        babet.getMode(special_dir .. "/special") == tonumber("777", 8))
    ok("archive file setuid bit stripped",
        babet.getMode(special_dir .. "/special/tool") == tonumber("755", 8))

    local existing_dir = root .. "/existing-dir"
    assert(babet.mkdir(existing_dir))
    assert(babet.mkdir(existing_dir .. "/kept"))
    assert(babet.setMode(existing_dir .. "/kept", "700"))
    local existing_zip = root .. "/existing-dir.zip"
    assert(make_zip(existing_zip, {
        { name = "kept/", permissions = tonumber("777", 8) },
        { name = "kept/file.txt", data = "ok" },
    }))
    local existing_result, existing_err = babet.archive.extract(
        existing_zip, existing_dir, { preserve_permissions = true })
    ok_val("archive.extract accepts an existing safe directory", existing_result, existing_err)
    ok("archive.extract does not chmod pre-existing directories",
        babet.getMode(existing_dir .. "/kept") == tonumber("700", 8))

    local single_parent = root .. "/single/nested"
    local single_path = single_parent .. "/renamed.dat"
    local single, single_err = babet.archive.extractFile(
        valid_zip, "binary.bin", single_path)
    ok_val("archive.extractFile extracts and renames one entry", single, single_err,
        function(value)
            return value.bytes == 4 and value.path == single_path
                and value.entry == "binary.bin"
        end)
    ok("archive.extractFile content is binary-safe",
        read_bytes(single_path) == "\0A\0B")
    ok("archive.extractFile uses basename, not archive path",
        babet.fileExists(single_parent .. "/binary.bin") == false)
    local single_again, single_again_err = babet.archive.extractFile(
        valid_zip, "binary.bin", single_path)
    ok_fail("archive.extractFile refuses overwrite by default",
        single_again, single_again_err)
    local single_overwrite, single_overwrite_err = babet.archive.extractFile(
        valid_zip, "binary.bin", single_path, { overwrite = true })
    ok_val("archive.extractFile overwrite=true",
        single_overwrite, single_overwrite_err)

    local single_mode_path = root .. "/single-mode.bin"
    local single_mode, single_mode_err = babet.archive.extractFile(
        valid_zip, "binary.bin", single_mode_path,
        { preserve_permissions = true })
    ok_val("archive.extractFile preserve_permissions",
        single_mode, single_mode_err)
    ok("archive.extractFile preserves regular permissions",
        babet.getMode(single_mode_path) == tonumber("701", 8),
        tostring(babet.getMode(single_mode_path)))

    local missing, missing_err = babet.archive.extractFile(
        valid_zip, "missing.txt", root .. "/missing.txt")
    ok_fail("archive.extractFile missing entry", missing, missing_err)
    local directory_file, directory_file_err = babet.archive.extractFile(
        valid_zip, "dir/", root .. "/not-a-file")
    ok_fail("archive.extractFile refuses a directory entry",
        directory_file, directory_file_err)

    local duplicate_zip = root .. "/duplicate.zip"
    assert(make_zip(duplicate_zip, {
        { name = "same.txt", data = "one" },
        { name = "same.txt", data = "two" },
    }))
    local duplicate_list, duplicate_list_err = babet.archive.list(duplicate_zip)
    ok_val("archive.list reports duplicate names", duplicate_list, duplicate_list_err,
        function(value)
            return value.count == 2
                and value.duplicates == 1
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
    do
        local duplicate_test, duplicate_test_err =
            babet.archive.test(duplicate_zip)
        ok_fail("archive.test rejects duplicate ZIP paths",
            duplicate_test, duplicate_test_err)
        ok("archive.test duplicate ZIP diagnostic is explicit",
            type(duplicate_test_err) == "string"
            and duplicate_test_err:find("duplicate output path", 1, true)
                ~= nil,
            "err=" .. tostring(duplicate_test_err))
    end
    local duplicate_extract, duplicate_extract_err = babet.archive.extract(
        duplicate_zip, root .. "/duplicate-out")
    ok_fail("archive.extract refuses duplicate output paths",
        duplicate_extract, duplicate_extract_err)
    do
        local duplicate_dry_out = root .. "/duplicate-dry-run-out"
        local duplicate_dry, duplicate_dry_err = babet.archive.extract(
            duplicate_zip, duplicate_dry_out, { dry_run = true })
        ok_fail("archive.extract dry_run rejects selected duplicate paths",
            duplicate_dry, duplicate_dry_err)
        ok("archive.extract duplicate dry_run creates no destination",
            babet.fileExists(duplicate_dry_out) == false)
    end
    local duplicate_one, duplicate_one_err = babet.archive.extractFile(
        duplicate_zip, "same.txt", root .. "/ambiguous.txt")
    ok_fail("archive.extractFile refuses an ambiguous duplicate name",
        duplicate_one, duplicate_one_err)

    do
        local filtered_duplicate_zip = root .. "/filtered-duplicate.zip"
        assert(make_zip(filtered_duplicate_zip, {
            { name = "same.txt", data = "first" },
            { name = "same.txt", data = "second" },
            { name = "safe.txt", data = "safe" },
        }))
        local filtered_out = root .. "/filtered-duplicate-zip-out"
        local filtered, filtered_err = babet.archive.extract(
            filtered_duplicate_zip, filtered_out,
            { include = { "safe.txt" } })
        ok_val("archive.extract ZIP ignores unselected duplicate paths",
            filtered, filtered_err, function(value)
                return value.entries == 1 and value.files == 1
                    and value.skipped == 2 and value.bytes == 4
            end)
        ok("archive.extract ZIP unselected duplicates publish only safe data",
            read_bytes(filtered_out .. "/safe.txt") == "safe"
            and babet.fileExists(filtered_out .. "/same.txt") == false)
    end

    local conflict_zip = root .. "/conflict.zip"
    assert(make_zip(conflict_zip, {
        { name = "node", data = "file" },
        { name = "node/child.txt", data = "child" },
    }))
    local conflict_list, conflict_list_err = babet.archive.list(conflict_zip)
    ok_val("archive.list reports ZIP file/directory conflicts",
        conflict_list, conflict_list_err, function(value)
            return value.duplicates == 0
                and value.conflicts == 1
                and value.entries[2].conflict == true
                and value.entries[2].conflict_with == 1
                and value.entries[2].conflict_reason
                    == "file/directory path conflict"
        end)
    do
        local conflict_test, conflict_test_err = babet.archive.test(conflict_zip)
        ok_fail("archive.test rejects ZIP file/directory path conflicts",
            conflict_test, conflict_test_err)
    end
    local conflict, conflict_err = babet.archive.extract(
        conflict_zip, root .. "/conflict-out")
    ok_fail("archive.extract refuses file/directory path conflicts",
        conflict, conflict_err)

    local normalized_conflict_zip = root .. "/normalized-conflict.zip"
    assert(make_zip(normalized_conflict_zip, {
        { name = "same/", data = "" },
        { name = "same", data = "file" },
    }))
    local normalized_conflict_list, normalized_conflict_list_err =
        babet.archive.list(normalized_conflict_zip)
    ok_val("archive.list distinguishes raw duplicates from normalized collisions",
        normalized_conflict_list, normalized_conflict_list_err,
        function(value)
            return value.duplicates == 0
                and value.conflicts == 1
                and value.entries[1].path == "same"
                and value.entries[2].path == "same"
                and value.entries[2].duplicate == false
                and value.entries[2].conflict == true
                and value.entries[2].conflict_with == 1
                and value.entries[2].conflict_reason
                    == "file/directory path conflict"
        end)

    ;(function()
    local unsafe_duplicate_zip = root .. "/unsafe-duplicate.zip"
    assert(make_zip(unsafe_duplicate_zip, {
        { name = "../same.txt", data = "first" },
        { name = "../same.txt", data = "second" },
    }))
    local unsafe_duplicate_list, unsafe_duplicate_list_err =
        babet.archive.list(unsafe_duplicate_zip)
    ok_val("archive.list reports raw duplicates even for unsafe paths",
        unsafe_duplicate_list, unsafe_duplicate_list_err, function(value)
            return value.duplicates == 1 and value.conflicts == 0
                and value.entries[2].safe_path == false
                and value.entries[2].duplicate == true
                and value.entries[2].duplicate_of == 1
                and value.entries[2].conflict == false
        end)
    end)()

    local unsafe_zip = root .. "/unsafe.zip"
    local long_name = string.rep("a", 4097)
    assert(make_zip(unsafe_zip, {
        { name = "../escape.txt", data = "x" },
        { name = "/absolute.txt", data = "x" },
        { name = "dir\\windows.txt", data = "x" },
        { name = "C:/drive.txt", data = "x" },
        { name = "D:drive-relative.txt", data = "x" },
        { name = "a//empty.txt", data = "x" },
        { name = "a/./dot.txt", data = "x" },
        { name = "a/../parent.txt", data = "x" },
        { name = long_name, data = "x" },
        { name = "safe.txt", data = "safe" },
    }))
    local unsafe_list, unsafe_list_err = babet.archive.list(unsafe_zip)
    ok_val("archive.list inspects unsafe paths without extracting",
        unsafe_list, unsafe_list_err, function(value) return value.count == 10 end)
    ok("archive.list marks traversal unsafe",
        unsafe_list and unsafe_list.entries[1].safe_path == false
        and unsafe_list.entries[1].extractable == false
        and type(unsafe_list.entries[1].reason) == "string")
    ok("archive.list marks absolute paths unsafe",
        unsafe_list and unsafe_list.entries[2].safe_path == false)
    ok("archive.list marks backslashes unsafe",
        unsafe_list and unsafe_list.entries[3].safe_path == false)
    ok("archive.list marks drive prefixes unsafe",
        unsafe_list and unsafe_list.entries[4].safe_path == false
        and unsafe_list.entries[5].safe_path == false)
    ok("archive.list marks empty components unsafe",
        unsafe_list and unsafe_list.entries[6].safe_path == false)
    ok("archive.list marks dot components unsafe",
        unsafe_list and unsafe_list.entries[7].safe_path == false
        and unsafe_list.entries[8].safe_path == false)
    ok("archive.list marks oversized names unsafe",
        unsafe_list and unsafe_list.entries[9].safe_path == false)
    do
        local unsafe_test, unsafe_test_err = babet.archive.test(unsafe_zip)
        ok_fail("archive.test rejects unsafe ZIP paths",
            unsafe_test, unsafe_test_err)
        ok("archive.test unsafe ZIP diagnostic is explicit",
            type(unsafe_test_err) == "string"
            and unsafe_test_err:find("cannot be extracted", 1, true) ~= nil,
            "err=" .. tostring(unsafe_test_err))
    end
    local strict_path_list, strict_path_list_err = babet.archive.list(
        unsafe_zip, { max_path_length = 4096 })
    ok_fail("archive.list may tighten metadata path length below its default",
        strict_path_list, strict_path_list_err)
    local unsafe_out = root .. "/unsafe-out"
    local unsafe_extract, unsafe_extract_err = babet.archive.extract(
        unsafe_zip, unsafe_out)
    ok_fail("archive.extract refuses unsafe archive paths",
        unsafe_extract, unsafe_extract_err)
    do
        local unsafe_dry_out = root .. "/unsafe-dry-run-out"
        local unsafe_dry, unsafe_dry_err = babet.archive.extract(
            unsafe_zip, unsafe_dry_out, { dry_run = true })
        ok_fail("archive.extract dry_run refuses selected unsafe archive paths",
            unsafe_dry, unsafe_dry_err)
        ok("archive path validation happens before destination creation",
            babet.fileExists(unsafe_out) == false
            and babet.fileExists(unsafe_dry_out) == false)
    end
    local selected_unsafe, selected_unsafe_err = babet.archive.extractFile(
        unsafe_zip, "../escape.txt", root .. "/selected-unsafe.txt")
    ok_fail("archive.extractFile refuses a selected unsafe entry",
        selected_unsafe, selected_unsafe_err)
    local selected_safe, selected_safe_err = babet.archive.extractFile(
        unsafe_zip, "safe.txt", root .. "/selected-safe.txt")
    ok_val("archive.extractFile may select a safe entry from a mixed archive",
        selected_safe, selected_safe_err)
    ok("selected safe entry content", read_bytes(root .. "/selected-safe.txt") == "safe")

    local selective_safe_out = root .. "/selective-safe-out"
    local selective_safe, selective_safe_err = babet.archive.extract(
        unsafe_zip, selective_safe_out, { include = { "safe.txt" } })
    ok_val("archive.extract ZIP may select a safe normalized path from a mixed archive",
        selective_safe, selective_safe_err, function(value)
            return value.entries == 1 and value.files == 1
                and value.skipped == 9 and value.bytes == 4
        end)
    ok("archive.extract ZIP selective mixed-archive extraction stays contained",
        read_bytes(selective_safe_out .. "/safe.txt") == "safe"
        and babet.fileExists(root .. "/escape.txt") == false)
    do
        local dry_out = root .. "/selective-safe-dry-out"
        local dry, dry_err = babet.archive.extract(
            unsafe_zip, dry_out, {
                dry_run = true,
                include = { "safe.txt" },
            })
        ok_val("archive.extract dry_run may preview a safe subset of a mixed ZIP",
            dry, dry_err, function(value)
                return value.entries == 1 and value.files == 1
                    and value.skipped == 9 and value.bytes == 4
                    and value.dry_run == true
                    and value.would_create == 1
                    and value.would_create_destination == true
            end)
        ok("archive.extract mixed ZIP dry_run creates nothing",
            babet.fileExists(dry_out) == false)
    end

    do
        local unsafe_exclude_out = root .. "/zip-exclude-unsafe-out"
        local unsafe_exclude, unsafe_exclude_err = babet.archive.extract(
            unsafe_zip, unsafe_exclude_out, { exclude = { "../escape.txt" } })
        ok_fail("archive.extract ZIP exclude-only cannot sanitize an unsafe path",
            unsafe_exclude, unsafe_exclude_err)
        ok("archive.extract ZIP unsafe exclude-only failure creates no destination",
            babet.fileExists(unsafe_exclude_out) == false)
    end

    local binary_name_zip = root .. "/binary-name.zip"
    local binary_name = "\255.bin"
    assert(make_zip(binary_name_zip, {
        { name = binary_name, data = "binary-name" },
    }))
    local binary_name_list, binary_name_list_err =
        babet.archive.list(binary_name_zip)
    ok_val("archive.list preserves non-UTF-8 ZIP names as Lua byte strings",
        binary_name_list, binary_name_list_err, function(value)
            return value.total_name_bytes == #binary_name
                and value.entries[1].name == binary_name
                and value.entries[1].path == binary_name
                and value.entries[1].valid_utf8 == false
                and value.entries[1].safe_path == true
        end)

    local nul_name_zip = root .. "/nul-name.zip"
    assert(make_zip(nul_name_zip, {
        { name = "visible.txt\0hidden.txt", data = "x" },
    }))
    local nul_name, nul_name_err = babet.archive.list(nul_name_zip)
    ok_fail("archive.list refuses an embedded NUL in a ZIP entry name",
        nul_name, nul_name_err)
    ok("archive embedded-NUL diagnostic is explicit",
        type(nul_name_err) == "string"
        and nul_name_err:find("embedded NUL", 1, true) ~= nil,
        tostring(nul_name_err))

    local symlink_zip = root .. "/symlink-entry.zip"
    assert(make_zip(symlink_zip, {
        {
            name = "link",
            data = "target.txt",
            external_attributes = zip_mode(0xA000, tonumber("777", 8)),
        },
    }))
    local symlink_list, symlink_list_err = babet.archive.list(symlink_zip)
    ok_val("archive.list identifies a ZIP symlink", symlink_list, symlink_list_err)
    ok("ZIP symlink is never extractable",
        symlink_list and symlink_list.entries[1].type == "symlink"
        and symlink_list.entries[1].extractable == false)
    do
        local symlink_test, symlink_test_err = babet.archive.test(symlink_zip)
        ok_fail("archive.test rejects ZIP symlink entries",
            symlink_test, symlink_test_err)
    end
    local symlink_entry, symlink_entry_err = babet.archive.extract(
        symlink_zip, root .. "/symlink-entry-out")
    ok_fail("archive.extract refuses ZIP symlink entries",
        symlink_entry, symlink_entry_err)
    do
        local symlink_dry_out = root .. "/symlink-entry-dry-out"
        local symlink_dry, symlink_dry_err = babet.archive.extract(
            symlink_zip, symlink_dry_out, { dry_run = true })
        ok_fail("archive.extract dry_run refuses selected ZIP symlink entries",
            symlink_dry, symlink_dry_err)
        ok("archive.extract ZIP symlink dry_run creates no destination",
            babet.fileExists(symlink_dry_out) == false)
    end

    local symlink_file, symlink_file_err = babet.archive.extractFile(
        symlink_zip, "link", root .. "/symlink-as-file")
    ok_fail("archive.extractFile refuses a ZIP symlink entry",
        symlink_file, symlink_file_err)

    local mac_symlink_zip = root .. "/mac-symlink-entry.zip"
    assert(make_zip(mac_symlink_zip, {
        {
            name = "mac-link",
            data = "target.txt",
            version_made_by = ((19 << 8) | 20),
            external_attributes = zip_mode(0xA000, tonumber("777", 8)),
        },
    }))
    local mac_symlink_list, mac_symlink_list_err =
        babet.archive.list(mac_symlink_zip)
    ok_val("archive.list identifies a macOS ZIP symlink",
        mac_symlink_list, mac_symlink_list_err)
    ok("macOS ZIP symlink is never extractable",
        mac_symlink_list
        and mac_symlink_list.entries[1].type == "symlink"
        and mac_symlink_list.entries[1].extractable == false)

    local special_type_zip = root .. "/special-type.zip"
    assert(make_zip(special_type_zip, {
        {
            name = "fifo",
            data = "",
            external_attributes = zip_mode(0x1000, tonumber("644", 8)),
        },
    }))
    local special_type_list, special_type_list_err = babet.archive.list(special_type_zip)
    ok_val("archive.list identifies unsupported filesystem types",
        special_type_list, special_type_list_err)
    ok("unsupported filesystem type is not extractable",
        special_type_list and special_type_list.entries[1].type == "unsupported"
        and special_type_list.entries[1].extractable == false)
    do
        local special_test, special_test_err =
            babet.archive.test(special_type_zip)
        ok_fail("archive.test rejects special ZIP filesystem types",
            special_test, special_test_err)
    end
    local special_type, special_type_err = babet.archive.extract(
        special_type_zip, root .. "/special-type-out")
    ok_fail("archive.extract refuses unsupported filesystem types",
        special_type, special_type_err)

    local encrypted_zip = root .. "/encrypted.zip"
    assert(make_zip(encrypted_zip, {
        { name = "secret.txt", data = "secret", flags = 1 },
    }))
    local encrypted_list, encrypted_list_err = babet.archive.list(encrypted_zip)
    ok_val("archive.list reports encryption", encrypted_list, encrypted_list_err)
    ok("encrypted entry is not extractable",
        encrypted_list and encrypted_list.entries[1].encrypted == true
        and encrypted_list.entries[1].extractable == false)
    do
        local encrypted_test, encrypted_test_err =
            babet.archive.test(encrypted_zip)
        ok_fail("archive.test refuses unverifiable encrypted ZIP entries",
            encrypted_test, encrypted_test_err)
        ok("archive.test encrypted ZIP diagnostic is explicit",
            type(encrypted_test_err) == "string"
            and encrypted_test_err:find("encrypted", 1, true) ~= nil,
            "err=" .. tostring(encrypted_test_err))
    end
    local encrypted, encrypted_err = babet.archive.extract(
        encrypted_zip, root .. "/encrypted-out")
    ok_fail("archive.extract refuses encrypted entries", encrypted, encrypted_err)

    local unsupported_zip = root .. "/unsupported-method.zip"
    assert(make_zip(unsupported_zip, {
        { name = "method.bin", data = "abc", method = 99 },
    }))
    local unsupported_list, unsupported_list_err = babet.archive.list(unsupported_zip)
    ok_val("archive.list reports unsupported compression",
        unsupported_list, unsupported_list_err)
    ok("unsupported compression is not extractable",
        unsupported_list and unsupported_list.entries[1].supported == false
        and unsupported_list.entries[1].extractable == false)
    do
        local unsupported_test, unsupported_test_err =
            babet.archive.test(unsupported_zip)
        ok_fail("archive.test refuses unsupported ZIP compression methods",
            unsupported_test, unsupported_test_err)
    end
    local unsupported, unsupported_err = babet.archive.extract(
        unsupported_zip, root .. "/unsupported-out")
    ok_fail("archive.extract refuses unsupported compression",
        unsupported, unsupported_err)

    local ratio_zip = root .. "/ratio.zip"
    assert(make_zip(ratio_zip, {
        {
            name = "ratio.txt", data = string.rep("A", 4096),
            payload = deflated_4096_a, method = 8,
        },
    }))
    local ratio_default, ratio_default_err = babet.archive.list(ratio_zip)
    ok_val("archive default compression ratio accepts normal DEFLATE",
        ratio_default, ratio_default_err)
    local ratio_limited, ratio_limited_err = babet.archive.list(
        ratio_zip, { max_compression_ratio = 100 })
    ok_fail("archive max_compression_ratio rejects suspicious expansion",
        ratio_limited, ratio_limited_err)

    local limited, limited_err = babet.archive.list(valid_zip, { max_entries = 4 })
    ok_fail("archive max_entries enforced", limited, limited_err)
    limited, limited_err = babet.archive.list(valid_zip, { max_entry_size = 4095 })
    ok_fail("archive max_entry_size enforced", limited, limited_err)
    limited, limited_err = babet.archive.list(valid_zip, { max_total_size = 4107 })
    ok_fail("archive max_total_size enforced", limited, limited_err)
    limited, limited_err = babet.archive.list(
        valid_zip, { max_path_length = 13 })
    ok_fail("archive max_path_length enforced", limited, limited_err)
    limited, limited_err = babet.archive.list(
        valid_zip, { max_total_name_bytes = 49 })
    ok_fail("archive max_total_name_bytes enforced", limited, limited_err)
    local exact_limits, exact_limits_err = babet.archive.list(valid_zip, {
        max_entries = 5,
        max_entry_size = 4096,
        max_total_size = 4108,
        max_path_length = 14,
        max_total_name_bytes = 50,
    })
    ok_val("archive anti-bomb integer limits are inclusive at the boundary",
        exact_limits, exact_limits_err,
        function(value)
            return value.count == 5
                and value.total_size == 4108
                and value.total_name_bytes == 50
        end)

    do
        local tested, tested_err = babet.archive.test(valid_zip, {
            max_entries = 5,
            max_entry_size = 4096,
            max_total_size = 4108,
            max_path_length = 14,
            max_total_name_bytes = 50,
            max_compression_ratio = 1000,
        })
        ok_val("archive.test accepts all six limits at valid boundaries",
            tested, tested_err, function(value)
                return value.entries == 5 and value.total_size == 4108
                    and value.total_name_bytes == 50
            end)

        tested, tested_err = babet.archive.test(valid_zip, {
            max_entry_size = 4095,
        })
        ok_fail("archive.test enforces max_entry_size", tested, tested_err)
        tested, tested_err = babet.archive.test(valid_zip, {
            max_total_size = 4107,
        })
        ok_fail("archive.test enforces max_total_size", tested, tested_err)
        tested, tested_err = babet.archive.test(valid_zip, {
            max_path_length = 13,
        })
        ok_fail("archive.test enforces max_path_length", tested, tested_err)
        tested, tested_err = babet.archive.test(valid_zip, {
            max_total_name_bytes = 49,
        })
        ok_fail("archive.test enforces max_total_name_bytes",
            tested, tested_err)
        tested, tested_err = babet.archive.test(ratio_zip, {
            max_compression_ratio = 100,
        })
        ok_fail("archive.test enforces max_compression_ratio",
            tested, tested_err)
    end

    local limited_out = root .. "/limited-out"
    limited, limited_err = babet.archive.extract(
        valid_zip, limited_out, { max_entries = 4 })
    ok_fail("archive.extract applies anti-bomb limits before writing",
        limited, limited_err)
    ok("archive.extract limit failure creates no destination",
        babet.fileExists(limited_out) == false)
    do
        local dry_limited_out = root .. "/dry-run-limited-out"
        local dry_limited, dry_limited_err = babet.archive.extract(
            valid_zip, dry_limited_out, {
                dry_run = true,
                max_entries = 4,
            })
        ok_fail("archive.extract dry_run applies anti-bomb limits",
            dry_limited, dry_limited_err)
        ok("archive.extract dry_run limit failure creates no destination",
            babet.fileExists(dry_limited_out) == false)
    end
    limited, limited_err = babet.archive.extractFile(
        valid_zip, "binary.bin", root .. "/limited-single.bin",
        { max_total_size = 4 })
    ok_fail("archive.extractFile applies limits to the whole archive",
        limited, limited_err)
    limited, limited_err = babet.archive.extract(
        valid_zip, root .. "/limited-name-out", { max_path_length = 13 })
    ok_fail("archive.extract applies max_path_length before writing",
        limited, limited_err)
    ok("archive.extract path-length failure creates no destination",
        babet.fileExists(root .. "/limited-name-out") == false)
    limited, limited_err = babet.archive.extractFile(
        valid_zip, "binary.bin", root .. "/limited-name-bytes.bin",
        { max_total_name_bytes = 49 })
    ok_fail("archive.extractFile applies max_total_name_bytes to the archive",
        limited, limited_err)

    local corrupt_zip = root .. "/corrupt.zip"
    local bad_data = "corrupted"
    assert(make_zip(corrupt_zip, {
        { name = "folder/", data = "" },
        { name = "folder/good.txt", data = "good" },
        {
            name = "folder/bad.txt",
            data = bad_data,
            crc32 = (crc32_number(bad_data) + 1) & 0xffffffff,
        },
    }))
    local corrupt_list, corrupt_list_err = babet.archive.list(corrupt_zip)
    ok_val("archive.list reports ZIP CRC metadata without reading every payload",
        corrupt_list, corrupt_list_err, function(value)
            return value.count == 3
                and value.entries[3].crc32
                    == ((crc32_number(bad_data) + 1) & 0xffffffff)
        end)
    do
        local corrupt_test, corrupt_test_err = babet.archive.test(corrupt_zip)
        ok_fail("archive.test detects corrupt ZIP data or CRC",
            corrupt_test, corrupt_test_err)
        ok("archive.test corrupt ZIP diagnostic identifies the failing entry",
            type(corrupt_test_err) == "string"
            and corrupt_test_err:find("folder/bad.txt", 1, true) ~= nil,
            "err=" .. tostring(corrupt_test_err))
    end
    do
        local dry_out = root .. "/corrupt-dry-run-out"
        local dry, dry_err = babet.archive.extract(
            corrupt_zip, dry_out, { dry_run = true })
        ok_fail("archive.extract dry_run detects corrupt selected ZIP data",
            dry, dry_err)
        ok("archive.extract corrupt dry_run creates no destination",
            babet.fileExists(dry_out) == false)

        local good_out = root .. "/corrupt-good-dry-run-out"
        local good, good_err = babet.archive.extract(
            corrupt_zip, good_out, {
                dry_run = true,
                include = { "folder/good.txt" },
            })
        ok_val("archive.extract dry_run skips unselected corrupt ZIP payloads",
            good, good_err, function(value)
                return value.entries == 1 and value.files == 1
                    and value.directories == 0 and value.skipped == 2
                    and value.bytes == 4 and value.dry_run == true
                    and value.would_create == 1
                    and value.would_create_destination == true
            end)
        ok("archive.extract selective corrupt dry_run creates nothing",
            babet.fileExists(good_out) == false)
    end

    local corrupt_out = root .. "/corrupt-out"
    local corrupt, corrupt_err = babet.archive.extract(corrupt_zip, corrupt_out)
    ok_fail("archive extraction detects corrupt data/CRC", corrupt, corrupt_err)
    ok("corrupt extraction publishes no earlier staged file",
        babet.fileExists(corrupt_out .. "/folder/good.txt") == false)
    ok("corrupt extraction publishes no bad file",
        babet.fileExists(corrupt_out .. "/folder/bad.txt") == false)
    ok("corrupt extraction removes staging files",
        no_archive_temporaries(corrupt_out))
    ok("corrupt extraction removes newly created empty subdirectories",
        babet.fileExists(corrupt_out .. "/folder") == false)

    do
        local corrupt_selected_out = root .. "/corrupt-selected-out"
        local corrupt_selected, corrupt_selected_err = babet.archive.extract(
            corrupt_zip, corrupt_selected_out, {
                include = { "folder/good.txt" },
            })
        ok_val("archive.extract ZIP does not inflate an unselected corrupt payload",
            corrupt_selected, corrupt_selected_err, function(value)
                return value.entries == 1 and value.files == 1
                    and value.directories == 0 and value.skipped == 2
                    and value.bytes == 4
            end)
        ok("archive.extract ZIP selected good payload is published independently",
            read_bytes(corrupt_selected_out .. "/folder/good.txt") == "good"
            and babet.fileExists(corrupt_selected_out .. "/folder/bad.txt") == false)
    end

    local not_zip = root .. "/not-a-zip.bin"
    assert(write_bytes(not_zip, "not a ZIP archive"))
    local invalid, invalid_err = babet.archive.list(not_zip)
    ok_fail("archive.list rejects malformed ZIP", invalid, invalid_err)
    invalid, invalid_err = babet.archive.test(not_zip)
    ok_fail("archive.test rejects malformed input", invalid, invalid_err)
    invalid, invalid_err = babet.archive.list(root .. "/missing.zip")
    ok_fail("archive.list rejects missing archive", invalid, invalid_err)
    invalid, invalid_err = babet.archive.test(root .. "/missing.zip")
    ok_fail("archive.test rejects a missing archive", invalid, invalid_err)

    invalid, invalid_err = babet.archive.list(root)
    ok_fail("archive.list rejects a directory as archive source",
        invalid, invalid_err)
    invalid, invalid_err = babet.archive.test(root)
    ok_fail("archive.test rejects a directory as archive source",
        invalid, invalid_err)

    local archive_fifo = root .. "/archive-input-fifo"
    local archive_fifo_created = babet.exec("mkfifo", { archive_fifo })
    ok("archive reader FIFO fixture created",
        type(archive_fifo_created) == "table" and archive_fifo_created.code == 0)
    local fifo_started = babet.time.monotonic()
    invalid, invalid_err = babet.archive.list(archive_fifo)
    local fifo_elapsed = babet.time.monotonic() - fifo_started
    ok_fail("archive.list rejects a FIFO as archive source",
        invalid, invalid_err)
    ok("archive.list rejects a FIFO without blocking",
        fifo_elapsed < 2, tostring(fifo_elapsed))
    do
        local test_fifo_started = babet.time.monotonic()
        invalid, invalid_err = babet.archive.test(archive_fifo)
        local test_fifo_elapsed = babet.time.monotonic() - test_fifo_started
        ok_fail("archive.test rejects a FIFO as archive source",
            invalid, invalid_err)
        ok("archive.test rejects a FIFO without blocking",
            test_fifo_elapsed < 2, tostring(test_fifo_elapsed))
    end
    babet.exec("rm", { "-f", archive_fifo })

    local archive_input_link = root .. "/archive-input-link.zip"
    local archive_link_created = babet.exec("ln", {
        "-s", "valid.zip", archive_input_link,
    })
    ok("archive reader symlink fixture created",
        type(archive_link_created) == "table" and archive_link_created.code == 0)
    local linked_archive, linked_archive_err = babet.archive.list(archive_input_link)
    ok_val("archive.list follows a read-only symlink to a regular ZIP",
        linked_archive, linked_archive_err,
        function(value) return value.count == 5 end)
    do
        local linked_test, linked_test_err =
            babet.archive.test(archive_input_link)
        ok_val("archive.test follows a symlink to a regular ZIP",
            linked_test, linked_test_err,
            function(value) return value.entries == 5 end)
    end

    local outside = root .. "/outside"
    local symlink_dest = root .. "/symlink-dest"
    assert(babet.mkdir(outside))
    assert(babet.mkdir(symlink_dest))
    assert(write_bytes(outside .. "/sentinel.txt", "unchanged"))
    local ln_parent = babet.exec("ln", {
        "-s", "../outside", symlink_dest .. "/dir",
    })
    ok("archive symlink-parent fixture created",
        type(ln_parent) == "table" and ln_parent.code == 0,
        ln_parent and ln_parent.stderr)
    local parent_attack, parent_attack_err = babet.archive.extract(
        valid_zip, symlink_dest, { overwrite = true })
    ok_fail("archive.extract refuses a symlinked destination parent",
        parent_attack, parent_attack_err)
    do
        local dry_parent_attack, dry_parent_attack_err = babet.archive.extract(
            valid_zip, symlink_dest, { dry_run = true, overwrite = true })
        ok_fail("archive.extract dry_run refuses a symlinked destination parent",
            dry_parent_attack, dry_parent_attack_err)
    end
    ok("symlinked parent cannot redirect extraction outside",
        read_bytes(outside .. "/sentinel.txt") == "unchanged"
        and babet.fileExists(outside .. "/hello.txt") == false)

    local root_link = root .. "/root-link"
    local ln_root = babet.exec("ln", { "-s", "outside", root_link })
    ok("archive symlink-root fixture created",
        type(ln_root) == "table" and ln_root.code == 0)
    local root_attack, root_attack_err = babet.archive.extract(
        valid_zip, root_link, { overwrite = true })
    ok_fail("archive.extract refuses a symlink in destination root",
        root_attack, root_attack_err)
    do
        local dry_root_attack, dry_root_attack_err = babet.archive.extract(
            valid_zip, root_link, { dry_run = true, overwrite = true })
        ok_fail("archive.extract dry_run refuses a symlink in destination root",
            dry_root_attack, dry_root_attack_err)
    end

    local leaf_dest = root .. "/leaf-dest"
    assert(babet.mkdir(leaf_dest))
    assert(write_bytes(outside .. "/leaf.txt", "outside"))
    local ln_leaf = babet.exec("ln", {
        "-s", "../outside/leaf.txt", leaf_dest .. "/binary.bin",
    })
    ok("archive symlink-leaf fixture created",
        type(ln_leaf) == "table" and ln_leaf.code == 0)
    local leaf_attack, leaf_attack_err = babet.archive.extractFile(
        valid_zip, "binary.bin", leaf_dest .. "/binary.bin",
        { overwrite = true })
    ok_fail("archive.extractFile refuses a symlink destination",
        leaf_attack, leaf_attack_err)
    ok("symlink destination target remains unchanged",
        read_bytes(outside .. "/leaf.txt") == "outside")
    do
        local dry_leaf_attack, dry_leaf_attack_err = babet.archive.extract(
            valid_zip, leaf_dest, {
                dry_run = true,
                overwrite = true,
                include = { "binary.bin" },
            })
        ok_fail("archive.extract dry_run refuses a symlink destination entry",
            dry_leaf_attack, dry_leaf_attack_err)
        ok("archive.extract dry_run leaves the symlink target unchanged",
            read_bytes(outside .. "/leaf.txt") == "outside")
    end

    do
        local conflict_destination = root .. "/dry-run-destination-conflict"
        assert(babet.mkdir(conflict_destination))
        assert(write_bytes(conflict_destination .. "/dir", "file"))
        local conflict, conflict_err = babet.archive.extract(
            valid_zip, conflict_destination, {
                dry_run = true,
                overwrite = true,
            })
        ok_fail("archive.extract dry_run refuses destination file/directory conflicts",
            conflict, conflict_err)
        ok("archive.extract dry_run destination conflict remains unchanged",
            read_bytes(conflict_destination .. "/dir") == "file"
            and no_archive_temporaries(conflict_destination))
    end

    local empty_destination, empty_destination_err =
        babet.archive.extract(valid_zip, "")
    ok_fail("archive.extract rejects an empty destination",
        empty_destination, empty_destination_err)

    local bad, bad_err = babet.archive.list(valid_zip, "bad")
    ok_fail("archive.list opts must be a table", bad, bad_err)
    bad, bad_err = babet.archive.test(valid_zip, "bad")
    ok_fail("archive.test opts must be a table", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, { overwrite = true })
    ok_fail("archive.list rejects extraction-only options", bad, bad_err)
    bad, bad_err = babet.archive.test(valid_zip, { overwrite = true })
    ok_fail("archive.test rejects extraction-only options", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, { unknown = true })
    ok_fail("archive.list rejects unknown options", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, { [1] = true })
    ok_fail("archive options require string keys", bad, bad_err)
    bad, bad_err = babet.archive.extract(valid_zip, root .. "/bad-options", {
        overwrite = 1,
    })
    ok_fail("archive overwrite option is strictly boolean", bad, bad_err)
    bad, bad_err = babet.archive.extract(valid_zip, root .. "/bad-options", {
        dry_run = 1,
    })
    ok_fail("archive dry_run option is strictly boolean", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, { dry_run = true })
    ok_fail("archive.list rejects dry_run", bad, bad_err)
    bad, bad_err = babet.archive.test(valid_zip, { dry_run = true })
    ok_fail("archive.test rejects dry_run", bad, bad_err)
    bad, bad_err = babet.archive.extractFile(
        valid_zip, "binary.bin", root .. "/bad-dry-run-file", {
            dry_run = true,
        })
    ok_fail("archive.extractFile rejects dry_run", bad, bad_err)
    bad, bad_err = babet.archive.extract(valid_zip, root .. "/bad-options", {
        include = "*.txt",
    })
    ok_fail("archive.extract include must be a dense array", bad, bad_err)
    bad, bad_err = babet.archive.extract(valid_zip, root .. "/bad-options", {
        exclude = { [1] = "*.txt", [3] = "*.tmp" },
    })
    ok_fail("archive.extract filter arrays must not contain holes", bad, bad_err)
    bad, bad_err = babet.archive.extract(valid_zip, root .. "/bad-options", {
        include = { 42 },
    })
    ok_fail("archive.extract filters require strict string values", bad, bad_err)
    bad, bad_err = babet.archive.extract(valid_zip, root .. "/bad-options", {
        include = { "" },
    })
    ok_fail("archive.extract rejects empty glob patterns", bad, bad_err)
    bad, bad_err = babet.archive.extract(valid_zip, root .. "/bad-options", {
        include = { "bad\0pattern" },
    })
    ok_fail("archive.extract rejects NUL bytes in glob patterns", bad, bad_err)
    bad, bad_err = babet.archive.extract(valid_zip, root .. "/bad-options", {
        include = { "trailing\\" },
    })
    ok_fail("archive.extract rejects a trailing glob escape", bad, bad_err)
    bad, bad_err = babet.archive.extract(valid_zip, root .. "/bad-options", {
        include = { string.rep("a", 4097) },
    })
    ok_fail("archive.extract enforces the 4096-byte per-pattern limit", bad, bad_err)
    bad = (function()
        local patterns = {}
        for i = 1, 257 do
            patterns[i] = "pattern-" .. tostring(i)
        end
        return patterns
    end)()
    bad, bad_err = babet.archive.extract(valid_zip, root .. "/bad-options", {
        include = bad,
    })
    ok_fail("archive.extract enforces the combined 256-pattern limit", bad, bad_err);

    -- Keep the separator: the next parenthesized function is a new
    -- statement, not a call on the nil result returned by ok_fail().
    (function()
        local exact_filter_bytes = (function()
            local patterns = {}
            for i = 1, 64 do
                patterns[i] = string.rep("a", 4096)
            end
            return patterns
        end)()
        local exact_filter_out = root .. "/exact-filter-bytes-out"
        local exact_filter, exact_filter_err = babet.archive.extract(
            empty_zip, exact_filter_out, { include = exact_filter_bytes })
        ok_val("archive.extract accepts the exact 256 KiB filter-byte boundary",
            exact_filter, exact_filter_err, function(value)
                return value.entries == 0 and value.skipped == 0
            end)
        ok("archive.extract exact filter-byte empty selection creates no destination",
            babet.fileExists(exact_filter_out) == false)
        exact_filter_bytes[#exact_filter_bytes + 1] = "x"
        bad, bad_err = babet.archive.extract(
            empty_zip, root .. "/bad-filter-bytes", {
                include = exact_filter_bytes,
            })
        ok_fail("archive.extract enforces the combined 256 KiB filter-byte limit",
            bad, bad_err)
    end)()
    bad, bad_err = babet.archive.extract(valid_zip, root .. "/bad-options", {
        unknown = true,
    })
    ok_fail("archive.extract rejects unknown options", bad, bad_err)
    bad, bad_err = babet.archive.extractFile(
        valid_zip, "binary.bin", root .. "/bad-filter-file", {
            include = { "binary.bin" },
        })
    ok_fail("archive.extractFile rejects selective-extraction options", bad, bad_err)
    bad, bad_err = babet.archive.extract(valid_zip, root .. "/bad-options", {
        preserve_permissions = "yes",
    })
    ok_fail("archive preserve_permissions option is strictly boolean", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, { max_entries = 1.0 })
    ok_fail("archive integer limits reject floating-point numbers", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, { max_entries = 0 })
    ok_fail("archive integer limits reject zero", bad, bad_err)
    bad, bad_err = babet.archive.test(valid_zip, { max_entries = 4 })
    ok_fail("archive.test applies anti-bomb limits", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, { max_entries = 100001 })
    ok_fail("archive max_entries hard ceiling enforced", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, { max_path_length = 1.0 })
    ok_fail("archive max_path_length requires an integer", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, { max_path_length = 0 })
    ok_fail("archive max_path_length rejects zero", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, {
        max_path_length = 1024 * 1024 + 1,
    })
    ok_fail("archive max_path_length hard ceiling enforced", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, {
        max_total_name_bytes = 1.0,
    })
    ok_fail("archive max_total_name_bytes requires an integer", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, {
        max_total_name_bytes = 0,
    })
    ok_fail("archive max_total_name_bytes rejects zero", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, {
        max_total_name_bytes = 64 * 1024 * 1024 + 1,
    })
    ok_fail("archive max_total_name_bytes hard ceiling enforced", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, {
        max_compression_ratio = 0.5,
    })
    ok_fail("archive ratio rejects values below one", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, {
        max_compression_ratio = 0 / 0,
    })
    ok_fail("archive ratio rejects NaN", bad, bad_err)
    bad, bad_err = babet.archive.list(valid_zip, {
        max_compression_ratio = math.huge,
    })
    ok_fail("archive ratio rejects infinity", bad, bad_err)

    ok_raises("archive.list enforces arity",
        function() return babet.archive.list() end,
        "expects 1 or 2 arguments")
    ok_raises("archive.list rejects excess arguments",
        function() return babet.archive.list(valid_zip, nil, true) end,
        "expects 1 or 2 arguments")
    ok_raises("archive.test enforces arity",
        function() return babet.archive.test() end,
        "expects 1 or 2 arguments")
    ok_raises("archive.test rejects excess arguments",
        function() return babet.archive.test(valid_zip, nil, true) end,
        "expects 1 or 2 arguments")
    ;(function()
        local long_name_zip = root .. "/filter-work-limit.zip"
        local long_name = string.rep("a", 4096)
        assert(make_zip(long_name_zip, {
            { name = long_name, data = "x" },
        }))
        local expensive = {}
        for i = 1, 7 do expensive[i] = string.rep("?", 4096) end
        local work_out = root .. "/filter-work-limit-out"
        local work_result, work_err = babet.archive.extract(
            long_name_zip, work_out, { include = expensive })
        ok_fail("archive.extract bounds cumulative glob matching work",
            work_result, work_err)
        ok("archive.extract glob work-limit failure creates no destination",
            babet.fileExists(work_out) == false)
    end)()

    ok_raises("archive.extract enforces arity",
        function() return babet.archive.extract(valid_zip) end,
        "expects 2 or 3 arguments")
    ok_raises("archive.extract rejects excess arguments",
        function()
            return babet.archive.extract(valid_zip, root .. "/x", nil, true)
        end,
        "expects 2 or 3 arguments")
    ok_raises("archive.extractFile enforces arity",
        function() return babet.archive.extractFile(valid_zip, "x") end,
        "expects 3 or 4 arguments")
    ok_raises("archive.extractFile rejects excess arguments",
        function()
            return babet.archive.extractFile(
                valid_zip, "binary.bin", root .. "/x", nil, true)
        end,
        "expects 3 or 4 arguments")
    ok_raises("archive.list rejects non-string path",
        function() return babet.archive.list({}) end, "string expected")
    ok_raises("archive.list rejects NUL in archive path",
        function() return babet.archive.list(valid_zip .. "\0ignored") end,
        "NUL")
    ok_raises("archive.test rejects non-string path",
        function() return babet.archive.test({}) end, "string expected")
    ok_raises("archive.test rejects NUL in archive path",
        function() return babet.archive.test(valid_zip .. "\0ignored") end,
        "NUL")
    ok_raises("archive.extract rejects NUL in destination",
        function()
            return babet.archive.extract(valid_zip, root .. "\0ignored")
        end,
        "NUL")
    ok_raises("archive.extractFile rejects NUL in entry name",
        function()
            return babet.archive.extractFile(
                valid_zip, "binary.bin\0ignored", root .. "/nul")
        end,
        "NUL")
    ok_raises("archive.extractFile rejects NUL in destination",
        function()
            return babet.archive.extractFile(
                valid_zip, "binary.bin", root .. "/nul\0ignored")
        end,
        "NUL")

end
