return function(test, context)
    local _ENV = test:environment(context)
    local create_source = context.create_source
    -- archive.create TAR (lot 4) --------------------------------------
    do
        local created_tar = root .. "/created.tar"
        local tar_created, tar_created_err = babet.archive.create(
            create_source, created_tar)
        ok_val("archive.create infers uncompressed TAR from .tar",
            tar_created, tar_created_err, function(value)
                return value.files == 3 and value.directories == 2
                    and value.bytes == 6 + 5 + #(string.rep("compress-me-", 2048))
                    and value.path == created_tar
                    and value.format == "tar"
                    and value.compression == "none"
                    and value.compression_level == nil
                    and value.deterministic == true
            end)
        ok("archive.create TAR publishes the destination",
            babet.isFile(created_tar) == true)
        local created_tar_mode, created_tar_mode_err = babet.getMode(created_tar)
        ok("archive.create TAR publishes with mode 0644",
            created_tar_mode == tonumber("644", 8) and created_tar_mode_err == nil,
            tostring(created_tar_mode_err))

        local created_tar_list, created_tar_list_err = babet.archive.list(created_tar)
        ok_val("archive.create TAR output is readable by archive.list",
            created_tar_list, created_tar_list_err,
            function(value)
                return value.format == "tar" and value.compression == "none"
                    and value.count == 5
            end)
        ok("archive.create TAR orders entries deterministically",
            created_tar_list
            and created_tar_list.entries[1].name == "alpha.txt"
            and created_tar_list.entries[2].name == "nested/"
            and created_tar_list.entries[3].name == "nested/binary.bin"
            and created_tar_list.entries[4].name == "nested/empty/"
            and created_tar_list.entries[5].name == "nested/repeated.txt")
        ok("archive.create TAR writes safe portable permission metadata",
            created_tar_list
            and created_tar_list.entries[1].unix_mode == tonumber("644", 8)
            and created_tar_list.entries[2].unix_mode == tonumber("755", 8))

        local tar_roundtrip = root .. "/tar-create-roundtrip"
        local tar_roundtrip_result, tar_roundtrip_err = babet.archive.extract(
            created_tar, tar_roundtrip)
        ok_val("archive.create TAR output extracts successfully",
            tar_roundtrip_result, tar_roundtrip_err)
        ok("archive.create TAR round-trip preserves text",
            read_bytes(tar_roundtrip .. "/alpha.txt") == "alpha\n")
        ok("archive.create TAR round-trip preserves binary bytes",
            read_bytes(tar_roundtrip .. "/nested/binary.bin") == "A\0B\255C")
        ok("archive.create TAR round-trip preserves empty directories",
            babet.isDir(tar_roundtrip .. "/nested/empty") == true)

        local tar_deterministic_a = root .. "/deterministic-a.tar"
        local tar_deterministic_b = root .. "/deterministic-b.tar"
        local tda, tda_err = babet.archive.create(create_source, tar_deterministic_a)
        local tdb, tdb_err = babet.archive.create(create_source, tar_deterministic_b)
        ok_val("archive.create TAR deterministic fixture A", tda, tda_err)
        ok_val("archive.create TAR deterministic fixture B", tdb, tdb_err)
        ok("archive.create TAR is byte-for-byte deterministic by default",
            read_bytes(tar_deterministic_a) == read_bytes(tar_deterministic_b))

        local function raw_tar_mtime(path)
            local raw = read_bytes(path)
            if not raw or #raw < 148 then return nil end
            local field = raw:sub(137, 148):gsub("%z.*", ""):gsub(" ", "")
            if field == "" then return 0 end
            return tonumber(field, 8)
        end
        ok("archive.create TAR deterministic timestamp is Unix epoch zero",
            raw_tar_mtime(created_tar) == 0,
            tostring(raw_tar_mtime(created_tar)))

        local tar_timestamp_source = root .. "/tar-timestamp-source"
        assert(babet.mkdir(tar_timestamp_source))
        assert(write_bytes(tar_timestamp_source .. "/stamp.txt", "timestamp"))
        local tar_timestamp_set = babet.exec("touch", {
            "-m", "-t", "200102030405.06", tar_timestamp_source .. "/stamp.txt",
        })
        ok("archive.create TAR source timestamp fixture created",
            type(tar_timestamp_set) == "table" and tar_timestamp_set.code == 0,
            tar_timestamp_set and tar_timestamp_set.stderr)
        local tar_stat = babet.exec("stat", {
            "-c", "%Y", tar_timestamp_source .. "/stamp.txt",
        })
        local tar_expected_mtime = tar_stat and tonumber(tar_stat.stdout)
        local nondeterministic_tar = root .. "/nondeterministic.tar"
        local ntar, ntar_err = babet.archive.create(
            tar_timestamp_source, nondeterministic_tar,
            { deterministic = false })
        ok_val("archive.create TAR accepts deterministic=false",
            ntar, ntar_err,
            function(value)
                return value.format == "tar" and value.deterministic == false
            end)
        ok("archive.create TAR deterministic=false stores source mtime",
            tar_expected_mtime ~= nil
            and raw_tar_mtime(nondeterministic_tar) == tar_expected_mtime,
            string.format("actual=%s expected=%s",
                tostring(raw_tar_mtime(nondeterministic_tar)),
                tostring(tar_expected_mtime)))

        local tar_old_source = root .. "/tar-old-source"
        assert(babet.mkdir(tar_old_source))
        assert(write_bytes(tar_old_source .. "/old.txt", "old"))
        local tar_old_set = babet.exec("touch", {
            "-m", "-d", "@0", tar_old_source .. "/old.txt",
        })
        ok("archive.create TAR pre-1980 timestamp fixture created",
            type(tar_old_set) == "table" and tar_old_set.code == 0,
            tar_old_set and tar_old_set.stderr)
        local tar_old_result, tar_old_err = babet.archive.create(
            tar_old_source, root .. "/old-timestamp.tar",
            { deterministic = false })
        ok_val("archive.create TAR accepts timestamps outside the ZIP DOS range",
            tar_old_result, tar_old_err)
        ok("archive.create TAR preserves the 1970 timestamp",
            raw_tar_mtime(root .. "/old-timestamp.tar") == 0,
            tostring(raw_tar_mtime(root .. "/old-timestamp.tar")))

        local tar_without_dirs = root .. "/without-directories.tar"
        local tar_no_dirs, tar_no_dirs_err = babet.archive.create(
            create_source, tar_without_dirs, { include_directories = false })
        ok_val("archive.create TAR include_directories=false",
            tar_no_dirs, tar_no_dirs_err,
            function(value)
                return value.files == 3 and value.directories == 0
            end)
        local tar_no_dirs_list = babet.archive.list(tar_without_dirs)
        ok("archive.create TAR omits explicit directories when requested",
            tar_no_dirs_list and tar_no_dirs_list.count == 3)
        local tar_no_dirs_out = root .. "/tar-no-dirs-out"
        local tar_no_dirs_extract = babet.archive.extract(
            tar_without_dirs, tar_no_dirs_out)
        ok("archive.create TAR without directory entries still extracts",
            tar_no_dirs_extract ~= nil
            and read_bytes(tar_no_dirs_out .. "/nested/binary.bin") == "A\0B\255C")
        ok("archive.create TAR cannot represent omitted empty directories",
            babet.isDir(tar_no_dirs_out .. "/nested/empty") == false)

        local uppercase_tar = root .. "/uppercase.TAR"
        local uppercase_tar_result, uppercase_tar_err = babet.archive.create(
            create_source, uppercase_tar)
        ok_val("archive.create infers TAR from a case-insensitive .tar suffix",
            uppercase_tar_result, uppercase_tar_err,
            function(value) return value.format == "tar" end)

        local explicit_tar = root .. "/explicit-format.data"
        local explicit_tar_result, explicit_tar_err = babet.archive.create(
            create_source, explicit_tar, { format = "tar" })
        ok_val("archive.create format='tar' overrides an unknown extension",
            explicit_tar_result, explicit_tar_err,
            function(value) return value.format == "tar" end)
        local explicit_tar_list = babet.archive.list(explicit_tar)
        ok("archive.create explicit TAR is detected from content",
            explicit_tar_list and explicit_tar_list.format == "tar")

        local explicit_zip = root .. "/explicit-zip.tar.gz"
        local explicit_zip_result, explicit_zip_err = babet.archive.create(
            create_source, explicit_zip, { format = "zip" })
        ok_val("archive.create format='zip' overrides a compressed TAR-looking extension",
            explicit_zip_result, explicit_zip_err,
            function(value) return value.format == "zip" end)
        local explicit_zip_list = babet.archive.list(explicit_zip)
        ok("archive.create explicit ZIP is detected from content",
            explicit_zip_list and explicit_zip_list.format == "zip")

        local legacy_extension = root .. "/legacy-extension.data"
        local legacy_zip, legacy_zip_err = babet.archive.create(
            create_source, legacy_extension)
        ok_val("archive.create keeps ZIP as the fallback for unknown extensions",
            legacy_zip, legacy_zip_err,
            function(value) return value.format == "zip" end)
        local legacy_zip_list = babet.archive.list(legacy_extension)
        ok("archive.create unknown-extension fallback is a ZIP",
            legacy_zip_list and legacy_zip_list.format == "zip")

        do
            local gzip_tar = root .. "/created.tar.gz"
            local gzip_created, gzip_created_err = babet.archive.create(
                create_source, gzip_tar)
            ok_val("archive.create infers gzip TAR from .tar.gz",
                gzip_created, gzip_created_err, function(value)
                    return value.files == 3 and value.directories == 2
                        and value.format == "tar"
                        and value.compression == "gzip"
                        and value.compression_level == 6
                        and value.deterministic == true
                end)
            local gzip_raw = read_bytes(gzip_tar)
            ok("archive.create gzip TAR writes the gzip signature",
                gzip_raw and gzip_raw:byte(1) == 0x1f
                and gzip_raw:byte(2) == 0x8b)
            local gz_mtime_1, gz_mtime_2, gz_mtime_3, gz_mtime_4
            if gzip_raw then
                gz_mtime_1, gz_mtime_2, gz_mtime_3, gz_mtime_4 =
                    gzip_raw:byte(5, 8)
            end
            ok("archive.create gzip header omits wall-clock timestamps",
                gz_mtime_1 == 0 and gz_mtime_2 == 0
                and gz_mtime_3 == 0 and gz_mtime_4 == 0)

            local gzip_list, gzip_list_err = babet.archive.list(gzip_tar)
            ok_val("archive.list detects created gzip TAR",
                gzip_list, gzip_list_err, function(value)
                    return value.format == "tar"
                        and value.compression == "gzip"
                        and value.count == 5
                        and value.total_size == 6 + 5
                            + #(string.rep("compress-me-", 2048))
                        and value.zip64 == nil
                end)
            ok("archive.list gzip TAR keeps ZIP-only entry metadata nil",
                gzip_list and gzip_list.entries[1]
                and gzip_list.entries[1].compressed_size == nil
                and gzip_list.entries[1].crc32 == nil
                and gzip_list.entries[1].compression_method == nil)
            do
                local gzip_test, gzip_test_err = babet.archive.test(gzip_tar)
                ok_val("archive.test validates a gzip-compressed TAR",
                    gzip_test, gzip_test_err, function(value)
                        return value.format == "tar"
                            and value.compression == "gzip"
                            and value.entries == gzip_list.count
                            and value.files == 3
                            and value.directories == 2
                            and value.total_size == gzip_list.total_size
                    end)
            end

            local disguised_gzip = root .. "/gzip-content.data"
            assert(write_bytes(disguised_gzip, assert(gzip_raw)))
            local disguised_list, disguised_list_err =
                babet.archive.list(disguised_gzip)
            ok_val("archive.list detects gzip TAR independently of extension",
                disguised_list, disguised_list_err, function(value)
                    return value.format == "tar"
                        and value.compression == "gzip"
                end)

            local tgz_path = root .. "/created-alias.tgz"
            local tgz_result, tgz_err = babet.archive.create(
                create_source, tgz_path)
            ok_val("archive.create infers gzip TAR from .tgz",
                tgz_result, tgz_err, function(value)
                    return value.format == "tar"
                        and value.compression == "gzip"
                end)
            local tgz_list = babet.archive.list(tgz_path)
            ok("archive.create .tgz output is detected as gzip TAR",
                tgz_list and tgz_list.compression == "gzip")

            local uppercase_tgz = root .. "/uppercase.TAR.GZ"
            local uppercase_gzip, uppercase_gzip_err = babet.archive.create(
                create_source, uppercase_tgz)
            ok_val("archive.create gzip TAR suffix matching is case-insensitive",
                uppercase_gzip, uppercase_gzip_err,
                function(value) return value.compression == "gzip" end)

            local explicit_gzip = root .. "/explicit-gzip.data"
            local explicit_gzip_result, explicit_gzip_err =
                babet.archive.create(create_source, explicit_gzip, {
                    format = "tar.gz",
                    compression_level = 9,
                })
            ok_val("archive.create format='tar.gz' overrides extension",
                explicit_gzip_result, explicit_gzip_err, function(value)
                    return value.format == "tar"
                        and value.compression == "gzip"
                        and value.compression_level == 9
                end)
            local explicit_gzip_list = babet.archive.list(explicit_gzip)
            ok("archive.create explicit gzip TAR is detected from content",
                explicit_gzip_list
                and explicit_gzip_list.compression == "gzip")

            local explicit_plain_tgz = root .. "/explicit-plain.tgz"
            local explicit_plain_result, explicit_plain_err =
                babet.archive.create(create_source, explicit_plain_tgz, {
                    format = "tar",
                })
            ok_val("archive.create format='tar' overrides a .tgz suffix",
                explicit_plain_result, explicit_plain_err,
                function(value) return value.compression == "none" end)
            local explicit_plain_list = babet.archive.list(explicit_plain_tgz)
            ok("explicit uncompressed TAR is detected from content",
                explicit_plain_list
                and explicit_plain_list.compression == "none")

            local gzip_deterministic_a = root .. "/gzip-deterministic-a.tar.gz"
            local gzip_deterministic_b = root .. "/gzip-deterministic-b.tar.gz"
            local gda, gda_err = babet.archive.create(
                create_source, gzip_deterministic_a)
            local gdb, gdb_err = babet.archive.create(
                create_source, gzip_deterministic_b)
            ok_val("archive.create gzip deterministic fixture A", gda, gda_err)
            ok_val("archive.create gzip deterministic fixture B", gdb, gdb_err)
            ok("archive.create gzip TAR is byte-for-byte deterministic",
                read_bytes(gzip_deterministic_a)
                    == read_bytes(gzip_deterministic_b))

            local concatenated_gzip = root .. "/concatenated-gzip.tar.gz"
            assert(write_bytes(concatenated_gzip,
                assert(read_bytes(gzip_deterministic_a))
                    .. assert(read_bytes(gzip_deterministic_b))))
            local concatenated_gzip_list, concatenated_gzip_list_err =
                babet.archive.list(concatenated_gzip)
            ok_val("archive.list traverses concatenated gzip members and TAR streams",
                concatenated_gzip_list, concatenated_gzip_list_err,
                function(value)
                    return value.compression == "gzip" and value.count == 10
                end)
            local concatenated_gzip_out = root .. "/concatenated-gzip-out"
            local concatenated_gzip_extract, concatenated_gzip_extract_err =
                babet.archive.extract(
                    concatenated_gzip, concatenated_gzip_out)
            ok_fail("archive.extract rejects duplicate paths across concatenated gzip TAR streams",
                concatenated_gzip_extract, concatenated_gzip_extract_err)
            ok("concatenated gzip duplicate refusal creates no destination",
                babet.fileExists(concatenated_gzip_out) == false)

            local gzip_stored = root .. "/gzip-level-zero.tar.gz"
            local gzip_stored_result, gzip_stored_err = babet.archive.create(
                create_source, gzip_stored, { compression_level = 0 })
            ok_val("archive.create gzip accepts compression_level=0",
                gzip_stored_result, gzip_stored_err,
                function(value) return value.compression_level == 0 end)
            ok("archive.create gzip level zero remains readable",
                babet.archive.list(gzip_stored) ~= nil)

            do
                local gzip_dry_run_out = root .. "/gzip-dry-run-out"
                local preview, preview_err = babet.archive.extract(
                    gzip_tar, gzip_dry_run_out, {
                        dry_run = true,
                        include = { "nested/binary.bin" },
                    })
                ok_val("archive.extract gzip TAR dry_run validates without writing",
                    preview, preview_err, function(value)
                        return value.entries == 1 and value.files == 1
                            and value.directories == 0 and value.skipped == 4
                            and value.bytes == 5 and value.dry_run == true
                            and value.would_create == 1
                            and value.would_create_destination == true
                    end)
                ok("archive.extract gzip TAR dry_run creates no destination",
                    babet.fileExists(gzip_dry_run_out) == false)
            end

            local gzip_roundtrip = root .. "/gzip-roundtrip"
            local gzip_extract, gzip_extract_err = babet.archive.extract(
                gzip_tar, gzip_roundtrip)
            ok_val("archive.extract extracts a gzip TAR",
                gzip_extract, gzip_extract_err, function(value)
                    return value.files == 3 and value.directories == 2
                end)
            ok("archive.extract gzip TAR preserves text and binary data",
                read_bytes(gzip_roundtrip .. "/alpha.txt") == "alpha\n"
                and read_bytes(gzip_roundtrip .. "/nested/binary.bin")
                    == "A\0B\255C")
            ok("archive.extract gzip TAR preserves empty directories",
                babet.isDir(gzip_roundtrip .. "/nested/empty") == true)

            do
                local selective_out = root .. "/gzip-selective-out"
                local selective, selective_err = babet.archive.extract(
                    gzip_tar, selective_out, { include = { "nested/binary.bin" } })
                ok_val("archive.extract gzip TAR applies selective filters",
                    selective, selective_err, function(value)
                        return value.entries == 1 and value.files == 1
                            and value.directories == 0 and value.skipped == 4
                            and value.bytes == 5
                    end)
                ok("archive.extract gzip TAR creates only required parents",
                    read_bytes(selective_out .. "/nested/binary.bin")
                        == "A\0B\255C"
                    and babet.fileExists(selective_out .. "/alpha.txt") == false
                    and babet.fileExists(selective_out .. "/nested/repeated.txt") == false)
            end

            local gzip_single = root .. "/gzip-single.bin"
            local gzip_single_result, gzip_single_err =
                babet.archive.extractFile(
                    gzip_tar, "nested/binary.bin", gzip_single)
            ok_val("archive.extractFile extracts from a gzip TAR",
                gzip_single_result, gzip_single_err,
                function(value) return value.bytes == 5 end)
            ok("archive.extractFile gzip TAR is binary-safe",
                read_bytes(gzip_single) == "A\0B\255C")

            local gzip_ratio_source = root .. "/gzip-ratio-source"
            assert(babet.mkdir(gzip_ratio_source))
            assert(write_bytes(gzip_ratio_source .. "/large.txt",
                string.rep("A", 256 * 1024)))
            local gzip_ratio_archive = root .. "/gzip-ratio.tar.gz"
            assert(babet.archive.create(
                gzip_ratio_source, gzip_ratio_archive,
                { compression_level = 9 }))
            ok("archive.list gzip TAR accepts the default ratio limit",
                babet.archive.list(gzip_ratio_archive) ~= nil)
            local gzip_ratio_rejected, gzip_ratio_rejected_err =
                babet.archive.list(gzip_ratio_archive, {
                    max_compression_ratio = 2,
                })
            ok_fail("archive.list gzip TAR enforces max_compression_ratio",
                gzip_ratio_rejected, gzip_ratio_rejected_err)
            local gzip_ratio_out = root .. "/gzip-ratio-out"
            local gzip_ratio_extract, gzip_ratio_extract_err =
                babet.archive.extract(gzip_ratio_archive, gzip_ratio_out, {
                    max_compression_ratio = 2,
                })
            ok_fail("archive.extract gzip TAR applies ratio limits before writing",
                gzip_ratio_extract, gzip_ratio_extract_err)
            ok("gzip ratio refusal creates no destination",
                babet.fileExists(gzip_ratio_out) == false)
            local gzip_ratio_single = root .. "/gzip-ratio-single"
            local gzip_ratio_file, gzip_ratio_file_err =
                babet.archive.extractFile(
                    gzip_ratio_archive, "large.txt", gzip_ratio_single, {
                        max_compression_ratio = 2,
                    })
            ok_fail("archive.extractFile gzip TAR applies ratio limits to the whole archive",
                gzip_ratio_file, gzip_ratio_file_err)
            ok("gzip ratio extractFile refusal creates no output",
                babet.fileExists(gzip_ratio_single) == false)

            local padded_gzip = root .. "/padded.tar.gz"
            assert(write_bytes(padded_gzip, gzip_raw .. string.rep("\0", 32)))
            local padded_gzip_list, padded_gzip_err =
                babet.archive.list(padded_gzip)
            ok_val("archive.list accepts standard zero padding after a gzip member",
                padded_gzip_list, padded_gzip_err,
                function(value) return value.compression == "gzip" end)

            local trailing_gzip = root .. "/trailing-garbage.tar.gz"
            assert(write_bytes(trailing_gzip, gzip_raw .. "X"))
            local trailing_gzip_list, trailing_gzip_err =
                babet.archive.list(trailing_gzip)
            ok_fail("archive.list rejects non-gzip trailing data after a gzip member",
                trailing_gzip_list, trailing_gzip_err)
            ok("single-byte gzip trailing-data error is explicit",
                type(trailing_gzip_err) == "string"
                and trailing_gzip_err:find(
                    "non-gzip trailing data", 1, true) ~= nil,
                "err=" .. tostring(trailing_gzip_err))

            local trailing_gzip_two = root .. "/trailing-garbage-two.tar.gz"
            assert(write_bytes(trailing_gzip_two, gzip_raw .. "XY"))
            local trailing_gzip_two_list, trailing_gzip_two_err =
                babet.archive.list(trailing_gzip_two)
            ok_fail("archive.list rejects two-byte non-gzip trailing data",
                trailing_gzip_two_list, trailing_gzip_two_err)
            ok("two-byte gzip trailing-data error is explicit",
                type(trailing_gzip_two_err) == "string"
                and trailing_gzip_two_err:find(
                    "non-gzip trailing data", 1, true) ~= nil,
                "err=" .. tostring(trailing_gzip_two_err))

            local corrupt_gzip = root .. "/corrupt.tar.gz"
            local crc_position = #gzip_raw - 7
            local corrupted = gzip_raw:sub(1, crc_position - 1)
                .. string.char(gzip_raw:byte(crc_position) ~ 1)
                .. gzip_raw:sub(crc_position + 1)
            assert(write_bytes(corrupt_gzip, corrupted))
            local corrupt_gzip_list, corrupt_gzip_list_err =
                babet.archive.list(corrupt_gzip)
            ok_fail("archive.list rejects a gzip TAR with a corrupt trailer",
                corrupt_gzip_list, corrupt_gzip_list_err)
            do
                local corrupt_gzip_test, corrupt_gzip_test_err =
                    babet.archive.test(corrupt_gzip)
                ok_fail("archive.test rejects a gzip TAR with a corrupt trailer",
                    corrupt_gzip_test, corrupt_gzip_test_err)
            end
            local corrupt_gzip_out = root .. "/corrupt-gzip-out"
            local corrupt_gzip_extract, corrupt_gzip_extract_err =
                babet.archive.extract(corrupt_gzip, corrupt_gzip_out)
            ok_fail("archive.extract rejects corrupt gzip before publication",
                corrupt_gzip_extract, corrupt_gzip_extract_err)
            ok("corrupt gzip extraction creates no destination",
                babet.fileExists(corrupt_gzip_out) == false)
            local corrupt_gzip_single = root .. "/corrupt-gzip-single"
            local corrupt_gzip_file, corrupt_gzip_file_err =
                babet.archive.extractFile(
                    corrupt_gzip, "alpha.txt", corrupt_gzip_single)
            ok_fail("archive.extractFile rejects corrupt gzip before publication",
                corrupt_gzip_file, corrupt_gzip_file_err)
            ok("corrupt gzip extractFile creates no output",
                babet.fileExists(corrupt_gzip_single) == false)

            local gzip_worker_code = [[
    local created, create_err = babet.archive.create(
        worker.args.source, worker.args.archive,
        { format = "tar.gz" })
    if not created then error(create_err) end
    local listed, list_err = babet.archive.list(worker.args.archive)
    if not listed then error(list_err) end
    local extracted, extract_err = babet.archive.extractFile(
        worker.args.archive, "alpha.txt", worker.args.output)
    if not extracted then error(extract_err) end
    return listed.compression
    ]]
            local gzip_worker = babet.workers.spawn(gzip_worker_code, {
                source = create_source,
                archive = root .. "/worker.tar.gz",
                output = root .. "/worker-gzip-alpha.txt",
            })
            ok("gzip TAR operations start in a worker", gzip_worker ~= nil)
            local gzip_worker_ok, gzip_worker_compression = false, nil
            if gzip_worker then
                gzip_worker_ok, gzip_worker_compression = gzip_worker:join()
            end
            ok("gzip TAR operations succeed in a worker",
                gzip_worker_ok == true
                and gzip_worker_compression == "gzip")
            ok("gzip TAR worker publishes expected data",
                read_bytes(root .. "/worker-gzip-alpha.txt") == "alpha\n");

            -- Keep the separator: the next parenthesized function is a new
            -- statement, not a call on the nil result returned by ok().
            (function()
                local xz_tar = root .. "/created.tar.xz"
                local xz_created, xz_created_err = babet.archive.create(
                    create_source, xz_tar)
                ok_val("archive.create infers xz TAR from .tar.xz",
                    xz_created, xz_created_err, function(value)
                        return value.files == 3 and value.directories == 2
                            and value.format == "tar"
                            and value.compression == "xz"
                            and value.compression_level == 6
                            and value.deterministic == true
                    end)
                local xz_raw = read_bytes(xz_tar)
                ok("archive.create xz TAR writes the xz signature",
                    xz_raw and xz_raw:sub(1, 6) == string.char(0xFD) .. "7zXZ\0")

                local xz_list, xz_list_err = babet.archive.list(xz_tar)
                ok_val("archive.list detects created xz TAR",
                    xz_list, xz_list_err, function(value)
                        return value.format == "tar"
                            and value.compression == "xz"
                            and value.count == 5
                            and value.total_size == 6 + 5
                                + #(string.rep("compress-me-", 2048))
                    end)
                ok("archive.list xz TAR keeps ZIP-only metadata nil",
                    xz_list and xz_list.entries[1]
                    and xz_list.entries[1].compressed_size == nil
                    and xz_list.entries[1].crc32 == nil
                    and xz_list.entries[1].compression_method == nil)
                do
                    local xz_test, xz_test_err = babet.archive.test(xz_tar)
                    ok_val("archive.test validates an xz-compressed TAR",
                        xz_test, xz_test_err, function(value)
                            return value.format == "tar"
                                and value.compression == "xz"
                                and value.entries == xz_list.count
                                and value.files == 3
                                and value.directories == 2
                                and value.total_size == xz_list.total_size
                        end)
                end

                local disguised_xz = root .. "/xz-content.data"
                assert(write_bytes(disguised_xz, assert(xz_raw)))
                local disguised_xz_list, disguised_xz_err =
                    babet.archive.list(disguised_xz)
                ok_val("archive.list detects xz TAR independently of extension",
                    disguised_xz_list, disguised_xz_err, function(value)
                        return value.format == "tar"
                            and value.compression == "xz"
                    end)

                local txz_path = root .. "/created-alias.txz"
                local txz_result, txz_err = babet.archive.create(
                    create_source, txz_path)
                ok_val("archive.create infers xz TAR from .txz",
                    txz_result, txz_err, function(value)
                        return value.format == "tar"
                            and value.compression == "xz"
                    end)
                local txz_list = babet.archive.list(txz_path)
                ok("archive.create .txz output is detected as xz TAR",
                    txz_list and txz_list.compression == "xz")

                local uppercase_xz = root .. "/uppercase.TAR.XZ"
                local uppercase_xz_result, uppercase_xz_err =
                    babet.archive.create(create_source, uppercase_xz)
                ok_val("archive.create xz suffix matching is case-insensitive",
                    uppercase_xz_result, uppercase_xz_err,
                    function(value) return value.compression == "xz" end)

                local explicit_xz = root .. "/explicit-xz.data"
                local explicit_xz_result, explicit_xz_err =
                    babet.archive.create(create_source, explicit_xz, {
                        format = "tar.xz",
                        compression_level = 9,
                    })
                ok_val("archive.create format='tar.xz' overrides extension",
                    explicit_xz_result, explicit_xz_err, function(value)
                        return value.format == "tar"
                            and value.compression == "xz"
                            and value.compression_level == 9
                    end)
                local explicit_xz_list = babet.archive.list(explicit_xz)
                ok("archive.create explicit xz TAR is detected from content",
                    explicit_xz_list
                    and explicit_xz_list.compression == "xz")

                local explicit_plain_txz = root .. "/explicit-plain.txz"
                local explicit_plain_txz_result, explicit_plain_txz_err =
                    babet.archive.create(create_source, explicit_plain_txz, {
                        format = "tar",
                    })
                ok_val("archive.create format='tar' overrides a .txz suffix",
                    explicit_plain_txz_result, explicit_plain_txz_err,
                    function(value) return value.compression == "none" end)
                local explicit_plain_txz_list =
                    babet.archive.list(explicit_plain_txz)
                ok("explicit uncompressed .txz is detected from content",
                    explicit_plain_txz_list
                    and explicit_plain_txz_list.compression == "none")

                local xz_deterministic_a = root .. "/xz-deterministic-a.tar.xz"
                local xz_deterministic_b = root .. "/xz-deterministic-b.tar.xz"
                local xda, xda_err = babet.archive.create(
                    create_source, xz_deterministic_a)
                local xdb, xdb_err = babet.archive.create(
                    create_source, xz_deterministic_b)
                ok_val("archive.create xz deterministic fixture A", xda, xda_err)
                ok_val("archive.create xz deterministic fixture B", xdb, xdb_err)
                ok("archive.create xz TAR is byte-for-byte deterministic",
                    read_bytes(xz_deterministic_a)
                        == read_bytes(xz_deterministic_b))

                local xz_level_zero = root .. "/xz-level-zero.tar.xz"
                local xz_zero, xz_zero_err = babet.archive.create(
                    create_source, xz_level_zero,
                    { compression_level = 0 })
                ok_val("archive.create xz accepts compression_level=0",
                    xz_zero, xz_zero_err,
                    function(value) return value.compression_level == 0 end)
                ok("archive.create xz level zero remains readable",
                    babet.archive.list(xz_level_zero) ~= nil)

                do
                    local xz_dry_run_out = root .. "/xz-dry-run-out"
                    local preview, preview_err = babet.archive.extract(
                        xz_tar, xz_dry_run_out, {
                            dry_run = true,
                            include = { "nested/binary.bin" },
                        })
                    ok_val("archive.extract xz TAR dry_run validates without writing",
                        preview, preview_err, function(value)
                            return value.entries == 1 and value.files == 1
                                and value.directories == 0 and value.skipped == 4
                                and value.bytes == 5 and value.dry_run == true
                                and value.would_create == 1
                                and value.would_create_destination == true
                        end)
                    ok("archive.extract xz TAR dry_run creates no destination",
                        babet.fileExists(xz_dry_run_out) == false)
                end

                local xz_roundtrip = root .. "/xz-roundtrip"
                local xz_extract, xz_extract_err = babet.archive.extract(
                    xz_tar, xz_roundtrip)
                ok_val("archive.extract extracts an xz TAR",
                    xz_extract, xz_extract_err, function(value)
                        return value.files == 3 and value.directories == 2
                    end)
                ok("archive.extract xz TAR preserves text and binary data",
                    read_bytes(xz_roundtrip .. "/alpha.txt") == "alpha\n"
                    and read_bytes(xz_roundtrip .. "/nested/binary.bin")
                        == "A\0B\255C")
                ok("archive.extract xz TAR preserves empty directories",
                    babet.isDir(xz_roundtrip .. "/nested/empty") == true)

                do
                    local selective_out = root .. "/xz-selective-out"
                    local selective, selective_err = babet.archive.extract(
                        xz_tar, selective_out, { include = { "nested/binary.bin" } })
                    ok_val("archive.extract xz TAR applies selective filters",
                        selective, selective_err, function(value)
                            return value.entries == 1 and value.files == 1
                                and value.directories == 0 and value.skipped == 4
                                and value.bytes == 5
                        end)
                    ok("archive.extract xz TAR creates only required parents",
                        read_bytes(selective_out .. "/nested/binary.bin")
                            == "A\0B\255C"
                        and babet.fileExists(selective_out .. "/alpha.txt") == false
                        and babet.fileExists(selective_out .. "/nested/repeated.txt") == false)
                end

                local xz_single = root .. "/xz-single.bin"
                local xz_single_result, xz_single_err =
                    babet.archive.extractFile(
                        xz_tar, "nested/binary.bin", xz_single)
                ok_val("archive.extractFile extracts from an xz TAR",
                    xz_single_result, xz_single_err,
                    function(value) return value.bytes == 5 end)
                ok("archive.extractFile xz TAR is binary-safe",
                    read_bytes(xz_single) == "A\0B\255C")

                local xz_ratio_source = root .. "/xz-ratio-source"
                assert(babet.mkdir(xz_ratio_source))
                assert(write_bytes(xz_ratio_source .. "/large.txt",
                    string.rep("A", 16 * 1024)))
                local xz_ratio_archive = root .. "/xz-ratio.tar.xz"
                assert(babet.archive.create(
                    xz_ratio_source, xz_ratio_archive,
                    { compression_level = 9 }))
                ok("archive.list xz TAR accepts the default ratio limit",
                    babet.archive.list(xz_ratio_archive) ~= nil)
                local xz_ratio_rejected, xz_ratio_rejected_err =
                    babet.archive.list(xz_ratio_archive, {
                        max_compression_ratio = 2,
                    })
                ok_fail("archive.list xz TAR enforces max_compression_ratio",
                    xz_ratio_rejected, xz_ratio_rejected_err)
                local xz_ratio_out = root .. "/xz-ratio-out"
                local xz_ratio_extract, xz_ratio_extract_err =
                    babet.archive.extract(xz_ratio_archive, xz_ratio_out, {
                        max_compression_ratio = 2,
                    })
                ok_fail("archive.extract xz TAR applies ratio limits before writing",
                    xz_ratio_extract, xz_ratio_extract_err)
                ok("xz ratio refusal creates no destination",
                    babet.fileExists(xz_ratio_out) == false)
                local xz_ratio_single = root .. "/xz-ratio-single"
                local xz_ratio_file, xz_ratio_file_err =
                    babet.archive.extractFile(
                        xz_ratio_archive, "large.txt", xz_ratio_single, {
                            max_compression_ratio = 2,
                        })
                ok_fail("archive.extractFile xz TAR applies ratio limits to the whole archive",
                    xz_ratio_file, xz_ratio_file_err)
                ok("xz ratio extractFile refusal creates no output",
                    babet.fileExists(xz_ratio_single) == false)

                local corrupt_xz = root .. "/corrupt.tar.xz"
                local corrupt_position = math.max(13, #xz_raw // 2)
                local corrupt_xz_raw = xz_raw:sub(1, corrupt_position - 1)
                    .. string.char(xz_raw:byte(corrupt_position) ~ 1)
                    .. xz_raw:sub(corrupt_position + 1)
                assert(write_bytes(corrupt_xz, corrupt_xz_raw))
                local corrupt_xz_list, corrupt_xz_list_err =
                    babet.archive.list(corrupt_xz)
                ok_fail("archive.list rejects a corrupt xz TAR",
                    corrupt_xz_list, corrupt_xz_list_err)
                do
                    local corrupt_xz_test, corrupt_xz_test_err =
                        babet.archive.test(corrupt_xz)
                    ok_fail("archive.test rejects a corrupt xz TAR",
                        corrupt_xz_test, corrupt_xz_test_err)
                end
                local corrupt_xz_out = root .. "/corrupt-xz-out"
                local corrupt_xz_extract, corrupt_xz_extract_err =
                    babet.archive.extract(corrupt_xz, corrupt_xz_out)
                ok_fail("archive.extract rejects corrupt xz before publication",
                    corrupt_xz_extract, corrupt_xz_extract_err)
                ok("corrupt xz extraction creates no destination",
                    babet.fileExists(corrupt_xz_out) == false)
                local corrupt_xz_single = root .. "/corrupt-xz-single"
                local corrupt_xz_file, corrupt_xz_file_err =
                    babet.archive.extractFile(
                        corrupt_xz, "alpha.txt", corrupt_xz_single)
                ok_fail("archive.extractFile rejects corrupt xz before publication",
                    corrupt_xz_file, corrupt_xz_file_err)
                ok("corrupt xz extractFile creates no output",
                    babet.fileExists(corrupt_xz_single) == false)

                local xz_worker_code = [[
    local created, create_err = babet.archive.create(
        worker.args.source, worker.args.archive,
        { format = "tar.xz" })
    if not created then error(create_err) end
    local listed, list_err = babet.archive.list(worker.args.archive)
    if not listed then error(list_err) end
    local extracted, extract_err = babet.archive.extractFile(
        worker.args.archive, "alpha.txt", worker.args.output)
    if not extracted then error(extract_err) end
    return listed.compression
    ]]
                local xz_worker = babet.workers.spawn(xz_worker_code, {
                    source = create_source,
                    archive = root .. "/worker.tar.xz",
                    output = root .. "/worker-xz-alpha.txt",
                })
                ok("xz TAR operations start in a worker", xz_worker ~= nil)
                local xz_worker_ok, xz_worker_compression = false, nil
                if xz_worker then
                    xz_worker_ok, xz_worker_compression = xz_worker:join()
                end
                ok("xz TAR operations succeed in a worker",
                    xz_worker_ok == true
                    and xz_worker_compression == "xz")
                ok("xz TAR worker publishes expected data",
                    read_bytes(root .. "/worker-xz-alpha.txt") == "alpha\n")
            end)()

            ;(function()
                local bzip2_tar = root .. "/created.tar.bz2"
                local bzip2_created, bzip2_created_err = babet.archive.create(
                    create_source, bzip2_tar)
                ok_val("archive.create infers bzip2 TAR from .tar.bz2",
                    bzip2_created, bzip2_created_err, function(value)
                        return value.files == 3 and value.directories == 2
                            and value.format == "tar"
                            and value.compression == "bzip2"
                            and value.compression_level == 6
                            and value.deterministic == true
                    end)
                local bzip2_raw = read_bytes(bzip2_tar)
                ok("archive.create bzip2 TAR writes the BZh signature",
                    bzip2_raw and bzip2_raw:sub(1, 3) == "BZh")

                local bzip2_list, bzip2_list_err =
                    babet.archive.list(bzip2_tar)
                ok_val("archive.list detects created bzip2 TAR",
                    bzip2_list, bzip2_list_err, function(value)
                        return value.format == "tar"
                            and value.compression == "bzip2"
                            and value.count == 5
                            and value.total_size == 6 + 5
                                + #(string.rep("compress-me-", 2048))
                    end)
                ok("archive.list bzip2 TAR keeps ZIP-only metadata nil",
                    bzip2_list and bzip2_list.entries[1]
                    and bzip2_list.entries[1].compressed_size == nil
                    and bzip2_list.entries[1].crc32 == nil
                    and bzip2_list.entries[1].compression_method == nil)
                do
                    local bzip2_test, bzip2_test_err =
                        babet.archive.test(bzip2_tar)
                    ok_val("archive.test validates a bzip2-compressed TAR",
                        bzip2_test, bzip2_test_err, function(value)
                            return value.format == "tar"
                                and value.compression == "bzip2"
                                and value.entries == bzip2_list.count
                                and value.files == 3
                                and value.directories == 2
                                and value.total_size == bzip2_list.total_size
                        end)
                end

                local disguised_bzip2 = root .. "/bzip2-content.data"
                assert(write_bytes(disguised_bzip2, assert(bzip2_raw)))
                local disguised_bzip2_list, disguised_bzip2_err =
                    babet.archive.list(disguised_bzip2)
                ok_val("archive.list detects bzip2 TAR independently of extension",
                    disguised_bzip2_list, disguised_bzip2_err,
                    function(value)
                        return value.format == "tar"
                            and value.compression == "bzip2"
                    end)

                local tbz2_path = root .. "/created-alias.tbz2"
                local tbz2_result, tbz2_err = babet.archive.create(
                    create_source, tbz2_path)
                ok_val("archive.create infers bzip2 TAR from .tbz2",
                    tbz2_result, tbz2_err, function(value)
                        return value.format == "tar"
                            and value.compression == "bzip2"
                    end)
                local tbz2_list = babet.archive.list(tbz2_path)
                ok("archive.create .tbz2 output is detected as bzip2 TAR",
                    tbz2_list and tbz2_list.compression == "bzip2")

                local tbz_path = root .. "/created-short-alias.tbz"
                local tbz_result, tbz_err = babet.archive.create(
                    create_source, tbz_path)
                ok_val("archive.create infers bzip2 TAR from .tbz",
                    tbz_result, tbz_err, function(value)
                        return value.compression == "bzip2"
                    end)

                local uppercase_bzip2 = root .. "/uppercase.TAR.BZ2"
                local uppercase_bzip2_result, uppercase_bzip2_err =
                    babet.archive.create(create_source, uppercase_bzip2)
                ok_val("archive.create bzip2 suffix matching is case-insensitive",
                    uppercase_bzip2_result, uppercase_bzip2_err,
                    function(value) return value.compression == "bzip2" end)

                local explicit_bzip2 = root .. "/explicit-bzip2.data"
                local explicit_bzip2_result, explicit_bzip2_err =
                    babet.archive.create(create_source, explicit_bzip2, {
                        format = "tar.bz2",
                        compression_level = 9,
                    })
                ok_val("archive.create format='tar.bz2' overrides extension",
                    explicit_bzip2_result, explicit_bzip2_err,
                    function(value)
                        return value.format == "tar"
                            and value.compression == "bzip2"
                            and value.compression_level == 9
                    end)
                local explicit_bzip2_list =
                    babet.archive.list(explicit_bzip2)
                ok("archive.create explicit bzip2 TAR is detected from content",
                    explicit_bzip2_list
                    and explicit_bzip2_list.compression == "bzip2")

                local explicit_plain_tbz2 = root .. "/explicit-plain.tbz2"
                local explicit_plain_tbz2_result, explicit_plain_tbz2_err =
                    babet.archive.create(create_source, explicit_plain_tbz2, {
                        format = "tar",
                    })
                ok_val("archive.create format='tar' overrides a .tbz2 suffix",
                    explicit_plain_tbz2_result, explicit_plain_tbz2_err,
                    function(value) return value.compression == "none" end)
                local explicit_plain_tbz2_list =
                    babet.archive.list(explicit_plain_tbz2)
                ok("explicit uncompressed .tbz2 is detected from content",
                    explicit_plain_tbz2_list
                    and explicit_plain_tbz2_list.compression == "none")

                local bzip2_deterministic_a =
                    root .. "/bzip2-deterministic-a.tar.bz2"
                local bzip2_deterministic_b =
                    root .. "/bzip2-deterministic-b.tar.bz2"
                local bda, bda_err = babet.archive.create(
                    create_source, bzip2_deterministic_a)
                local bdb, bdb_err = babet.archive.create(
                    create_source, bzip2_deterministic_b)
                ok_val("archive.create bzip2 deterministic fixture A",
                    bda, bda_err)
                ok_val("archive.create bzip2 deterministic fixture B",
                    bdb, bdb_err)
                ok("archive.create bzip2 TAR is byte-for-byte deterministic",
                    read_bytes(bzip2_deterministic_a)
                        == read_bytes(bzip2_deterministic_b))

                local bzip2_level_one = root .. "/bzip2-level-one.tar.bz2"
                local bzip2_one, bzip2_one_err = babet.archive.create(
                    create_source, bzip2_level_one,
                    { compression_level = 1 })
                ok_val("archive.create bzip2 accepts compression_level=1",
                    bzip2_one, bzip2_one_err,
                    function(value) return value.compression_level == 1 end)
                ok("archive.create bzip2 level one remains readable",
                    babet.archive.list(bzip2_level_one) ~= nil)

                local bzip2_zero, bzip2_zero_err = babet.archive.create(
                    create_source, root .. "/bzip2-level-zero.tar.bz2",
                    { compression_level = 0 })
                ok_fail("archive.create bzip2 rejects compression_level=0",
                    bzip2_zero, bzip2_zero_err)

                do
                    local bzip2_dry_run_out = root .. "/bzip2-dry-run-out"
                    local preview, preview_err = babet.archive.extract(
                        bzip2_tar, bzip2_dry_run_out, {
                            dry_run = true,
                            include = { "nested/binary.bin" },
                        })
                    ok_val("archive.extract bzip2 TAR dry_run validates without writing",
                        preview, preview_err, function(value)
                            return value.entries == 1 and value.files == 1
                                and value.directories == 0 and value.skipped == 4
                                and value.bytes == 5 and value.dry_run == true
                                and value.would_create == 1
                                and value.would_create_destination == true
                        end)
                    ok("archive.extract bzip2 TAR dry_run creates no destination",
                        babet.fileExists(bzip2_dry_run_out) == false)
                end

                local bzip2_out = root .. "/bzip2-out"
                local bzip2_extract, bzip2_extract_err =
                    babet.archive.extract(bzip2_tar, bzip2_out)
                ok_val("archive.extract extracts a bzip2 TAR",
                    bzip2_extract, bzip2_extract_err)
                ok("archive.extract bzip2 TAR preserves text and binary data",
                    read_bytes(bzip2_out .. "/alpha.txt") == "alpha\n"
                    and read_bytes(bzip2_out .. "/nested/binary.bin")
                        == "A\0B\255C")
                ok("archive.extract bzip2 TAR preserves empty directories",
                    babet.isDir(bzip2_out .. "/nested/empty") == true)

                do
                    local selective_out = root .. "/bzip2-selective-out"
                    local selective, selective_err = babet.archive.extract(
                        bzip2_tar, selective_out, { include = { "nested/binary.bin" } })
                    ok_val("archive.extract bzip2 TAR applies selective filters",
                        selective, selective_err, function(value)
                            return value.entries == 1 and value.files == 1
                                and value.directories == 0 and value.skipped == 4
                                and value.bytes == 5
                        end)
                    ok("archive.extract bzip2 TAR creates only required parents",
                        read_bytes(selective_out .. "/nested/binary.bin")
                            == "A\0B\255C"
                        and babet.fileExists(selective_out .. "/alpha.txt") == false
                        and babet.fileExists(selective_out .. "/nested/repeated.txt") == false)
                end

                local bzip2_single = root .. "/bzip2-single.bin"
                local bzip2_file, bzip2_file_err = babet.archive.extractFile(
                    bzip2_tar, "nested/binary.bin", bzip2_single)
                ok_val("archive.extractFile extracts from a bzip2 TAR",
                    bzip2_file, bzip2_file_err)
                ok("archive.extractFile bzip2 TAR is binary-safe",
                    read_bytes(bzip2_single) == "A\0B\255C")

                local ratio_source = root .. "/bzip2-ratio-source"
                assert(babet.mkdir(ratio_source))
                assert(write_bytes(ratio_source .. "/ratio.txt",
                    string.rep("A", 16 * 1024)))
                local ratio_archive = root .. "/bzip2-ratio.tar.bz2"
                local ratio_created, ratio_created_err =
                    babet.archive.create(ratio_source, ratio_archive, {
                        compression_level = 9,
                    })
                ok_val("archive.create bzip2 ratio fixture",
                    ratio_created, ratio_created_err)
                local ratio_default, ratio_default_err =
                    babet.archive.list(ratio_archive)
                ok_val("archive.list bzip2 TAR accepts the default ratio limit",
                    ratio_default, ratio_default_err)
                local ratio_limited, ratio_limited_err =
                    babet.archive.list(ratio_archive, {
                        max_compression_ratio = 2,
                    })
                ok_fail("archive.list bzip2 TAR enforces max_compression_ratio",
                    ratio_limited, ratio_limited_err)
                local ratio_out = root .. "/bzip2-ratio-out"
                local ratio_extract, ratio_extract_err =
                    babet.archive.extract(ratio_archive, ratio_out, {
                        max_compression_ratio = 2,
                    })
                ok_fail("archive.extract bzip2 TAR applies ratio limits before writing",
                    ratio_extract, ratio_extract_err)
                ok("bzip2 ratio refusal creates no destination",
                    babet.fileExists(ratio_out) == false)
                local ratio_single = root .. "/bzip2-ratio-single"
                local ratio_file, ratio_file_err =
                    babet.archive.extractFile(
                        ratio_archive, "ratio.txt", ratio_single, {
                            max_compression_ratio = 2,
                        })
                ok_fail("archive.extractFile bzip2 TAR applies ratio limits to the whole archive",
                    ratio_file, ratio_file_err)
                ok("bzip2 ratio extractFile refusal creates no output",
                    babet.fileExists(ratio_single) == false)

                local corrupt_bzip2 = root .. "/corrupt.tar.bz2"
                local corrupt_position = 20
                local corrupt_bzip2_raw = bzip2_raw:sub(1, corrupt_position - 1)
                    .. string.char(bzip2_raw:byte(corrupt_position) ~ 1)
                    .. bzip2_raw:sub(corrupt_position + 1)
                assert(write_bytes(corrupt_bzip2, corrupt_bzip2_raw))
                local corrupt_bzip2_list, corrupt_bzip2_list_err =
                    babet.archive.list(corrupt_bzip2)
                ok_fail("archive.list rejects a corrupt bzip2 TAR",
                    corrupt_bzip2_list, corrupt_bzip2_list_err)
                do
                    local corrupt_bzip2_test, corrupt_bzip2_test_err =
                        babet.archive.test(corrupt_bzip2)
                    ok_fail("archive.test rejects a corrupt bzip2 TAR",
                        corrupt_bzip2_test, corrupt_bzip2_test_err)
                end
                local corrupt_bzip2_out = root .. "/corrupt-bzip2-out"
                local corrupt_bzip2_extract, corrupt_bzip2_extract_err =
                    babet.archive.extract(corrupt_bzip2, corrupt_bzip2_out)
                ok_fail("archive.extract rejects corrupt bzip2 before publication",
                    corrupt_bzip2_extract, corrupt_bzip2_extract_err)
                ok("corrupt bzip2 extraction creates no destination",
                    babet.fileExists(corrupt_bzip2_out) == false)
                local corrupt_bzip2_single =
                    root .. "/corrupt-bzip2-single"
                local corrupt_bzip2_file, corrupt_bzip2_file_err =
                    babet.archive.extractFile(
                        corrupt_bzip2, "alpha.txt", corrupt_bzip2_single)
                ok_fail("archive.extractFile rejects corrupt bzip2 before publication",
                    corrupt_bzip2_file, corrupt_bzip2_file_err)
                ok("corrupt bzip2 extractFile creates no output",
                    babet.fileExists(corrupt_bzip2_single) == false)

                local bzip2_worker_code = [[
    local created, create_err = babet.archive.create(
        worker.args.source, worker.args.archive,
        { format = "tar.bz2" })
    if not created then error(create_err) end
    local listed, list_err = babet.archive.list(worker.args.archive)
    if not listed then error(list_err) end
    local extracted, extract_err = babet.archive.extractFile(
        worker.args.archive, "alpha.txt", worker.args.output)
    if not extracted then error(extract_err) end
    return listed.compression
    ]]
                local bzip2_worker = babet.workers.spawn(bzip2_worker_code, {
                    source = create_source,
                    archive = root .. "/worker.tar.bz2",
                    output = root .. "/worker-bzip2-alpha.txt",
                })
                ok("bzip2 TAR operations start in a worker",
                    bzip2_worker ~= nil)
                local bzip2_worker_ok, bzip2_worker_compression = false, nil
                if bzip2_worker then
                    bzip2_worker_ok, bzip2_worker_compression =
                        bzip2_worker:join()
                end
                ok("bzip2 TAR operations succeed in a worker",
                    bzip2_worker_ok == true
                    and bzip2_worker_compression == "bzip2")
                ok("bzip2 TAR worker publishes expected data",
                    read_bytes(root .. "/worker-bzip2-alpha.txt")
                        == "alpha\n")
            end)()

            ;(function()
                local zstd_tar = root .. "/created.tar.zst"
                local zstd_created, zstd_created_err = babet.archive.create(
                    create_source, zstd_tar)
                ok_val("archive.create infers zstd TAR from .tar.zst",
                    zstd_created, zstd_created_err, function(value)
                        return value.files == 3 and value.directories == 2
                            and value.format == "tar"
                            and value.compression == "zstd"
                            and value.compression_level == 6
                            and value.deterministic == true
                    end)
                local zstd_raw = read_bytes(zstd_tar)
                ok("archive.create zstd TAR writes the zstd signature",
                    zstd_raw and zstd_raw:sub(1, 4)
                        == string.char(0x28, 0xB5, 0x2F, 0xFD))

                local zstd_list, zstd_list_err =
                    babet.archive.list(zstd_tar)
                ok_val("archive.list detects created zstd TAR",
                    zstd_list, zstd_list_err, function(value)
                        return value.format == "tar"
                            and value.compression == "zstd"
                            and value.count == 5
                            and value.total_size == 6 + 5
                                + #(string.rep("compress-me-", 2048))
                    end)
                ok("archive.list zstd TAR keeps ZIP-only metadata nil",
                    zstd_list and zstd_list.entries[1]
                    and zstd_list.entries[1].compressed_size == nil
                    and zstd_list.entries[1].crc32 == nil
                    and zstd_list.entries[1].compression_method == nil)
                do
                    local zstd_test, zstd_test_err =
                        babet.archive.test(zstd_tar)
                    ok_val("archive.test validates a zstd-compressed TAR",
                        zstd_test, zstd_test_err, function(value)
                            return value.format == "tar"
                                and value.compression == "zstd"
                                and value.entries == zstd_list.count
                                and value.files == 3
                                and value.directories == 2
                                and value.total_size == zstd_list.total_size
                        end)
                end

                local disguised_zstd = root .. "/zstd-content.data"
                assert(write_bytes(disguised_zstd, assert(zstd_raw)))
                local disguised_zstd_list, disguised_zstd_err =
                    babet.archive.list(disguised_zstd)
                ok_val("archive.list detects zstd TAR independently of extension",
                    disguised_zstd_list, disguised_zstd_err,
                    function(value)
                        return value.format == "tar"
                            and value.compression == "zstd"
                    end)

                local tzst_path = root .. "/created-alias.tzst"
                local tzst_result, tzst_err = babet.archive.create(
                    create_source, tzst_path)
                ok_val("archive.create infers zstd TAR from .tzst",
                    tzst_result, tzst_err, function(value)
                        return value.format == "tar"
                            and value.compression == "zstd"
                    end)
                local tzst_list = babet.archive.list(tzst_path)
                ok("archive.create .tzst output is detected as zstd TAR",
                    tzst_list and tzst_list.compression == "zstd")

                local tar_zstd_path = root .. "/created-long-alias.tar.zstd"
                local tar_zstd_result, tar_zstd_err = babet.archive.create(
                    create_source, tar_zstd_path)
                ok_val("archive.create infers zstd TAR from .tar.zstd",
                    tar_zstd_result, tar_zstd_err, function(value)
                        return value.compression == "zstd"
                    end)

                local uppercase_zstd = root .. "/uppercase.TAR.ZST"
                local uppercase_zstd_result, uppercase_zstd_err =
                    babet.archive.create(create_source, uppercase_zstd)
                ok_val("archive.create zstd suffix matching is case-insensitive",
                    uppercase_zstd_result, uppercase_zstd_err,
                    function(value) return value.compression == "zstd" end)

                local explicit_zstd = root .. "/explicit-zstd.data"
                local explicit_zstd_result, explicit_zstd_err =
                    babet.archive.create(create_source, explicit_zstd, {
                        format = "tar.zst",
                        compression_level = 19,
                    })
                ok_val("archive.create format='tar.zst' overrides extension",
                    explicit_zstd_result, explicit_zstd_err,
                    function(value)
                        return value.format == "tar"
                            and value.compression == "zstd"
                            and value.compression_level == 19
                    end)
                local explicit_zstd_list = babet.archive.list(explicit_zstd)
                ok("archive.create explicit zstd TAR is detected from content",
                    explicit_zstd_list
                    and explicit_zstd_list.compression == "zstd")

                local explicit_plain_tzst = root .. "/explicit-plain.tzst"
                local explicit_plain_tzst_result, explicit_plain_tzst_err =
                    babet.archive.create(create_source, explicit_plain_tzst, {
                        format = "tar",
                    })
                ok_val("archive.create format='tar' overrides a .tzst suffix",
                    explicit_plain_tzst_result, explicit_plain_tzst_err,
                    function(value) return value.compression == "none" end)
                local explicit_plain_tzst_list =
                    babet.archive.list(explicit_plain_tzst)
                ok("explicit uncompressed .tzst is detected from content",
                    explicit_plain_tzst_list
                    and explicit_plain_tzst_list.compression == "none")

                local zstd_deterministic_a =
                    root .. "/zstd-deterministic-a.tar.zst"
                local zstd_deterministic_b =
                    root .. "/zstd-deterministic-b.tar.zst"
                local zda, zda_err = babet.archive.create(
                    create_source, zstd_deterministic_a)
                local zdb, zdb_err = babet.archive.create(
                    create_source, zstd_deterministic_b)
                ok_val("archive.create zstd deterministic fixture A",
                    zda, zda_err)
                ok_val("archive.create zstd deterministic fixture B",
                    zdb, zdb_err)
                ok("archive.create zstd TAR is byte-for-byte deterministic",
                    read_bytes(zstd_deterministic_a)
                        == read_bytes(zstd_deterministic_b))

                local zstd_level_zero = root .. "/zstd-level-zero.tar.zst"
                local zstd_zero, zstd_zero_err = babet.archive.create(
                    create_source, zstd_level_zero,
                    { compression_level = 0 })
                ok_val("archive.create zstd accepts compression_level=0",
                    zstd_zero, zstd_zero_err,
                    function(value) return value.compression_level == 0 end)
                ok("archive.create zstd level zero remains readable",
                    babet.archive.list(zstd_level_zero) ~= nil)

                local zstd_level_nineteen =
                    root .. "/zstd-level-nineteen.tar.zst"
                local zstd_nineteen, zstd_nineteen_err =
                    babet.archive.create(create_source, zstd_level_nineteen,
                        { compression_level = 19 })
                ok_val("archive.create zstd accepts compression_level=19",
                    zstd_nineteen, zstd_nineteen_err,
                    function(value) return value.compression_level == 19 end)

                local zstd_twenty, zstd_twenty_err = babet.archive.create(
                    create_source, root .. "/zstd-level-twenty.tar.zst",
                    { compression_level = 20 })
                ok_fail("archive.create zstd rejects compression_level=20",
                    zstd_twenty, zstd_twenty_err)

                do
                    local zstd_dry_run_out = root .. "/zstd-dry-run-out"
                    local preview, preview_err = babet.archive.extract(
                        zstd_tar, zstd_dry_run_out, {
                            dry_run = true,
                            include = { "nested/binary.bin" },
                        })
                    ok_val("archive.extract zstd TAR dry_run validates without writing",
                        preview, preview_err, function(value)
                            return value.entries == 1 and value.files == 1
                                and value.directories == 0 and value.skipped == 4
                                and value.bytes == 5 and value.dry_run == true
                                and value.would_create == 1
                                and value.would_create_destination == true
                        end)
                    ok("archive.extract zstd TAR dry_run creates no destination",
                        babet.fileExists(zstd_dry_run_out) == false)
                end

                local zstd_out = root .. "/zstd-out"
                local zstd_extract, zstd_extract_err =
                    babet.archive.extract(zstd_tar, zstd_out)
                ok_val("archive.extract extracts a zstd TAR",
                    zstd_extract, zstd_extract_err)
                ok("archive.extract zstd TAR preserves text and binary data",
                    read_bytes(zstd_out .. "/alpha.txt") == "alpha\n"
                    and read_bytes(zstd_out .. "/nested/binary.bin")
                        == "A\0B\255C")
                ok("archive.extract zstd TAR preserves empty directories",
                    babet.isDir(zstd_out .. "/nested/empty") == true)

                do
                    local selective_out = root .. "/zstd-selective-out"
                    local selective, selective_err = babet.archive.extract(
                        zstd_tar, selective_out, { include = { "nested/binary.bin" } })
                    ok_val("archive.extract zstd TAR applies selective filters",
                        selective, selective_err, function(value)
                            return value.entries == 1 and value.files == 1
                                and value.directories == 0 and value.skipped == 4
                                and value.bytes == 5
                        end)
                    ok("archive.extract zstd TAR creates only required parents",
                        read_bytes(selective_out .. "/nested/binary.bin")
                            == "A\0B\255C"
                        and babet.fileExists(selective_out .. "/alpha.txt") == false
                        and babet.fileExists(selective_out .. "/nested/repeated.txt") == false)
                end

                local zstd_single = root .. "/zstd-single.bin"
                local zstd_file, zstd_file_err = babet.archive.extractFile(
                    zstd_tar, "nested/binary.bin", zstd_single)
                ok_val("archive.extractFile extracts from a zstd TAR",
                    zstd_file, zstd_file_err)
                ok("archive.extractFile zstd TAR is binary-safe",
                    read_bytes(zstd_single) == "A\0B\255C")

                local ratio_source = root .. "/zstd-ratio-source"
                assert(babet.mkdir(ratio_source))
                assert(write_bytes(ratio_source .. "/ratio.txt",
                    string.rep("A", 16 * 1024)))
                local ratio_archive = root .. "/zstd-ratio.tar.zst"
                local ratio_created, ratio_created_err =
                    babet.archive.create(ratio_source, ratio_archive, {
                        compression_level = 19,
                    })
                ok_val("archive.create zstd ratio fixture",
                    ratio_created, ratio_created_err)
                local ratio_default, ratio_default_err =
                    babet.archive.list(ratio_archive)
                ok_val("archive.list zstd TAR accepts the default ratio limit",
                    ratio_default, ratio_default_err)
                local ratio_limited, ratio_limited_err =
                    babet.archive.list(ratio_archive, {
                        max_compression_ratio = 2,
                    })
                ok_fail("archive.list zstd TAR enforces max_compression_ratio",
                    ratio_limited, ratio_limited_err)
                local ratio_out = root .. "/zstd-ratio-out"
                local ratio_extract, ratio_extract_err =
                    babet.archive.extract(ratio_archive, ratio_out, {
                        max_compression_ratio = 2,
                    })
                ok_fail("archive.extract zstd TAR applies ratio limits before writing",
                    ratio_extract, ratio_extract_err)
                ok("zstd ratio refusal creates no destination",
                    babet.fileExists(ratio_out) == false)
                local ratio_single = root .. "/zstd-ratio-single"
                local ratio_file, ratio_file_err =
                    babet.archive.extractFile(
                        ratio_archive, "ratio.txt", ratio_single, {
                            max_compression_ratio = 2,
                        })
                ok_fail("archive.extractFile zstd TAR applies ratio limits to the whole archive",
                    ratio_file, ratio_file_err)
                ok("zstd ratio extractFile refusal creates no output",
                    babet.fileExists(ratio_single) == false)

                local concatenated_zstd = root .. "/concatenated.tar.zst"
                local second_zstd_raw = read_bytes(zstd_deterministic_b)
                assert(write_bytes(concatenated_zstd,
                    assert(zstd_raw) .. assert(second_zstd_raw)))
                local concatenated_list, concatenated_list_err =
                    babet.archive.list(concatenated_zstd)
                ok_val("archive.list traverses concatenated zstd frames and TAR streams",
                    concatenated_list, concatenated_list_err,
                    function(value) return value.count == 10 end)
                local concatenated_out = root .. "/concatenated-zstd-out"
                local concatenated_extract, concatenated_extract_err =
                    babet.archive.extract(concatenated_zstd, concatenated_out)
                ok_fail("archive.extract rejects duplicate paths across concatenated zstd TAR streams",
                    concatenated_extract, concatenated_extract_err)
                ok("concatenated zstd duplicate refusal creates no destination",
                    babet.fileExists(concatenated_out) == false)

                local trailing_zstd = root .. "/trailing.tar.zst"
                assert(write_bytes(trailing_zstd, assert(zstd_raw) .. "X"))
                local trailing_zstd_list, trailing_zstd_list_err =
                    babet.archive.list(trailing_zstd)
                ok_fail("archive.list rejects non-zstd trailing data after a zstd TAR",
                    trailing_zstd_list, trailing_zstd_list_err)
                local trailing_zstd_out = root .. "/trailing-zstd-out"
                local trailing_zstd_extract, trailing_zstd_extract_err =
                    babet.archive.extract(trailing_zstd, trailing_zstd_out)
                ok_fail("archive.extract rejects zstd trailing data before publication",
                    trailing_zstd_extract, trailing_zstd_extract_err)
                ok("zstd trailing-data refusal creates no destination",
                    babet.fileExists(trailing_zstd_out) == false)

                local corrupt_zstd = root .. "/corrupt.tar.zst"
                local corrupt_position = #zstd_raw - 2
                local corrupt_zstd_raw = zstd_raw:sub(1, corrupt_position - 1)
                    .. string.char(zstd_raw:byte(corrupt_position) ~ 1)
                    .. zstd_raw:sub(corrupt_position + 1)
                assert(write_bytes(corrupt_zstd, corrupt_zstd_raw))
                local corrupt_zstd_list, corrupt_zstd_list_err =
                    babet.archive.list(corrupt_zstd)
                ok_fail("archive.list rejects a corrupt zstd TAR",
                    corrupt_zstd_list, corrupt_zstd_list_err)
                do
                    local corrupt_zstd_test, corrupt_zstd_test_err =
                        babet.archive.test(corrupt_zstd)
                    ok_fail("archive.test rejects a corrupt zstd TAR",
                        corrupt_zstd_test, corrupt_zstd_test_err)
                end
                local corrupt_zstd_out = root .. "/corrupt-zstd-out"
                local corrupt_zstd_extract, corrupt_zstd_extract_err =
                    babet.archive.extract(corrupt_zstd, corrupt_zstd_out)
                ok_fail("archive.extract rejects corrupt zstd before publication",
                    corrupt_zstd_extract, corrupt_zstd_extract_err)
                ok("corrupt zstd extraction creates no destination",
                    babet.fileExists(corrupt_zstd_out) == false)
                local corrupt_zstd_single = root .. "/corrupt-zstd-single"
                local corrupt_zstd_file, corrupt_zstd_file_err =
                    babet.archive.extractFile(
                        corrupt_zstd, "alpha.txt", corrupt_zstd_single)
                ok_fail("archive.extractFile rejects corrupt zstd before publication",
                    corrupt_zstd_file, corrupt_zstd_file_err)
                ok("corrupt zstd extractFile creates no output",
                    babet.fileExists(corrupt_zstd_single) == false)

                local zstd_worker_code = [[
    local created, create_err = babet.archive.create(
        worker.args.source, worker.args.archive,
        { format = "tar.zst" })
    if not created then error(create_err) end
    local listed, list_err = babet.archive.list(worker.args.archive)
    if not listed then error(list_err) end
    local extracted, extract_err = babet.archive.extractFile(
        worker.args.archive, "alpha.txt", worker.args.output)
    if not extracted then error(extract_err) end
    return listed.compression
    ]]
                local zstd_worker = babet.workers.spawn(zstd_worker_code, {
                    source = create_source,
                    archive = root .. "/worker.tar.zst",
                    output = root .. "/worker-zstd-alpha.txt",
                })
                ok("zstd TAR operations start in a worker",
                    zstd_worker ~= nil)
                local zstd_worker_ok, zstd_worker_compression = false, nil
                if zstd_worker then
                    zstd_worker_ok, zstd_worker_compression =
                        zstd_worker:join()
                end
                ok("zstd TAR operations succeed in a worker",
                    zstd_worker_ok == true
                    and zstd_worker_compression == "zstd")
                ok("zstd TAR worker publishes expected data",
                    read_bytes(root .. "/worker-zstd-alpha.txt")
                        == "alpha\n")
            end)()
        end

        local tar_level, tar_level_err = babet.archive.create(
            create_source, root .. "/invalid-level.tar",
            { compression_level = 0 })
        ok_fail("archive.create rejects compression_level for inferred TAR",
            tar_level, tar_level_err)
        local explicit_tar_level, explicit_tar_level_err = babet.archive.create(
            create_source, root .. "/invalid-explicit-level.data",
            { format = "tar", compression_level = 0 })
        ok_fail("archive.create rejects compression_level for explicit TAR",
            explicit_tar_level, explicit_tar_level_err)

        local tar_overwrite_path = root .. "/overwrite.tar"
        assert(write_bytes(tar_overwrite_path, "keep"))
        local tar_overwrite_refused, tar_overwrite_refused_err =
            babet.archive.create(create_source, tar_overwrite_path)
        ok_fail("archive.create TAR refuses overwrite by default",
            tar_overwrite_refused, tar_overwrite_refused_err)
        ok("archive.create TAR overwrite refusal preserves destination",
            read_bytes(tar_overwrite_path) == "keep")
        local tar_overwrite, tar_overwrite_err = babet.archive.create(
            create_source, tar_overwrite_path, { overwrite = true })
        ok_val("archive.create TAR overwrite=true publishes atomically",
            tar_overwrite, tar_overwrite_err)
        ok("archive.create TAR overwritten output is valid",
            babet.archive.list(tar_overwrite_path) ~= nil)

        local empty_tar_source = root .. "/empty-tar-source"
        assert(babet.mkdir(empty_tar_source))
        local empty_created_tar = root .. "/empty-created.tar"
        local empty_tar, empty_tar_err = babet.archive.create(
            empty_tar_source, empty_created_tar)
        ok_val("archive.create supports an empty TAR source directory",
            empty_tar, empty_tar_err,
            function(value)
                return value.files == 0 and value.directories == 0
            end)
        local empty_tar_list = babet.archive.list(empty_created_tar)
        ok("archive.create empty TAR produces an empty archive",
            empty_tar_list and empty_tar_list.count == 0)

        local long_tar_source = root .. "/long-tar-source"
        local long_tar_component = string.rep("p", 180)
        assert(babet.mkdir(long_tar_source .. "/" .. long_tar_component))
        assert(write_bytes(long_tar_source .. "/" .. long_tar_component .. "/x.txt",
            "pax-long-name"))
        local long_tar = root .. "/long-path.tar"
        local long_tar_result, long_tar_err = babet.archive.create(
            long_tar_source, long_tar)
        ok_val("archive.create TAR emits pax headers for long paths",
            long_tar_result, long_tar_err)
        local long_tar_list = babet.archive.list(long_tar)
        ok("archive.create TAR preserves a path longer than ustar name fields",
            long_tar_list and long_tar_list.entries[2]
            and long_tar_list.entries[2].name == long_tar_component .. "/x.txt")
        local long_tar_out = root .. "/long-tar-out"
        local long_tar_extract = babet.archive.extract(long_tar, long_tar_out)
        ok("archive.create TAR long-path archive extracts safely",
            long_tar_extract ~= nil
            and read_bytes(long_tar_out .. "/" .. long_tar_component .. "/x.txt")
                == "pax-long-name")

        local tar_worker_code = [[
    local result, err = babet.archive.create(
        worker.args.source, worker.args.destination, { format = "tar" })
    if not result then error(err) end
    return result.format
    ]]
        local tar_worker_a = babet.workers.spawn(tar_worker_code, {
            source = create_source, destination = root .. "/worker-a.tar",
        })
        local tar_worker_b = babet.workers.spawn(tar_worker_code, {
            source = create_source, destination = root .. "/worker-b.tar",
        })
        ok("archive.create TAR starts safely in concurrent workers",
            tar_worker_a ~= nil and tar_worker_b ~= nil)
        local tar_worker_a_ok, tar_worker_a_format = false, nil
        local tar_worker_b_ok, tar_worker_b_format = false, nil
        if tar_worker_a and tar_worker_b then
            tar_worker_a_ok, tar_worker_a_format = tar_worker_a:join()
            tar_worker_b_ok, tar_worker_b_format = tar_worker_b:join()
        end
        ok("archive.create TAR succeeds concurrently in worker states",
            tar_worker_a_ok == true and tar_worker_a_format == "tar"
            and tar_worker_b_ok == true and tar_worker_b_format == "tar")
        ok("concurrent deterministic TAR outputs are identical",
            read_bytes(root .. "/worker-a.tar")
                == read_bytes(root .. "/worker-b.tar"))
    end

    local deterministic_a = root .. "/deterministic-a.zip"
    local deterministic_b = root .. "/deterministic-b.zip"
    local da, da_err = babet.archive.create(create_source, deterministic_a)
    local db, db_err = babet.archive.create(create_source, deterministic_b)
    ok_val("archive.create deterministic fixture A", da, da_err)
    ok_val("archive.create deterministic fixture B", db, db_err)
    ok("archive.create is byte-for-byte deterministic by default",
        read_bytes(deterministic_a) == read_bytes(deterministic_b))
    local timestamp_source = root .. "/timestamp-source"
    assert(babet.mkdir(timestamp_source))
    assert(write_bytes(timestamp_source .. "/stamp.txt", "timestamp"))
    local timestamp_set = babet.exec("touch", {
        "-m", "-t", "200102030405.06", timestamp_source .. "/stamp.txt",
    })
    ok("archive.create source timestamp fixture created",
        type(timestamp_set) == "table" and timestamp_set.code == 0,
        timestamp_set and timestamp_set.stderr)
    local nondeterministic_zip = root .. "/nondeterministic.zip"
    local nondeterministic, nondeterministic_err = babet.archive.create(
        timestamp_source, nondeterministic_zip, { deterministic = false })
    ok_val("archive.create accepts deterministic=false",
        nondeterministic, nondeterministic_err,
        function(value) return value.deterministic == false end)
    local nondeterministic_raw = read_bytes(nondeterministic_zip)
    local nd_time_lo, nd_time_hi, nd_date_lo, nd_date_hi
    if nondeterministic_raw then
        nd_time_lo, nd_time_hi, nd_date_lo, nd_date_hi =
            string.byte(nondeterministic_raw, 11, 14)
    end
    ok("archive.create deterministic=false stores the exact source timestamp",
        nd_time_lo == 0xA3 and nd_time_hi == 0x20
        and nd_date_lo == 0x43 and nd_date_hi == 0x2A,
        string.format("%s,%s,%s,%s", tostring(nd_time_lo),
            tostring(nd_time_hi), tostring(nd_date_lo), tostring(nd_date_hi)))

    local old_timestamp_source = root .. "/old-timestamp-source"
    assert(babet.mkdir(old_timestamp_source))
    assert(write_bytes(old_timestamp_source .. "/old.txt", "old"))
    local old_timestamp_set = babet.exec("touch", {
        "-m", "-t", "197001010000.00", old_timestamp_source .. "/old.txt",
    })
    ok("archive.create pre-1980 timestamp fixture created",
        type(old_timestamp_set) == "table" and old_timestamp_set.code == 0,
        old_timestamp_set and old_timestamp_set.stderr)
    local old_timestamp_zip = root .. "/old-timestamp.zip"
    local old_timestamp, old_timestamp_err = babet.archive.create(
        old_timestamp_source, old_timestamp_zip, { deterministic = false })
    ok_fail("archive.create rejects source timestamps outside the ZIP range",
        old_timestamp, old_timestamp_err)
    ok("archive.create timestamp-range failure leaves no output",
        babet.fileExists(old_timestamp_zip) == false)
    local old_deterministic, old_deterministic_err = babet.archive.create(
        old_timestamp_source, root .. "/old-deterministic.zip")
    ok_val("archive.create deterministic mode ignores unrepresentable source times",
        old_deterministic, old_deterministic_err)

    local stored_zip = root .. "/stored.zip"
    local stored, stored_err = babet.archive.create(create_source, stored_zip, {
        compression_level = 0,
        include_directories = false,
    })
    ok_val("archive.create accepts compression_level=0",
        stored, stored_err, function(value)
            return value.compression_level == 0 and value.directories == 0
        end)
    local stored_list, stored_list_err = babet.archive.list(stored_zip)
    ok_val("archive.create stored archive is readable", stored_list, stored_list_err)
    ok("archive.create compression_level=0 stores files",
        stored_list and stored_list.entries[3].compression_method == 0,
        tostring(stored_list and stored_list.entries[3].compression_method))
    ok("archive.create include_directories=false omits directory entries",
        stored_list and stored_list.count == 3
        and stored_list.entries[1].name == "alpha.txt"
        and stored_list.entries[2].name == "nested/binary.bin"
        and stored_list.entries[3].name == "nested/repeated.txt")
    local implicit_out = root .. "/implicit-directories"
    local implicit, implicit_err = babet.archive.extract(stored_zip, implicit_out)
    ok_val("archive without directory entries still extracts", implicit, implicit_err)
    ok("implicit directories are created during extraction",
        read_bytes(implicit_out .. "/nested/binary.bin") == "A\0B\255C")

    assert(write_bytes(root .. "/overwrite.zip", "sentinel"))
    local refused_create, refused_create_err = babet.archive.create(
        create_source, root .. "/overwrite.zip")
    ok_fail("archive.create refuses overwrite by default",
        refused_create, refused_create_err)
    ok("archive.create refusal preserves existing destination",
        read_bytes(root .. "/overwrite.zip") == "sentinel")
    local overwritten, overwritten_err = babet.archive.create(
        create_source, root .. "/overwrite.zip", { overwrite = true })
    ok_val("archive.create overwrite=true replaces atomically",
        overwritten, overwritten_err)
    ok("archive.create overwrite result is a valid ZIP",
        type(babet.archive.list(root .. "/overwrite.zip")) == "table")

    local empty_source = root .. "/empty-source"
    assert(babet.mkdir(empty_source))
    local empty_created, empty_created_err = babet.archive.create(
        empty_source, root .. "/empty-created.zip")
    ok_val("archive.create supports an empty source directory",
        empty_created, empty_created_err,
        function(value) return value.files == 0 and value.directories == 0 end)
    local empty_created_list = babet.archive.list(root .. "/empty-created.zip")
    ok("archive.create empty source produces an empty ZIP",
        type(empty_created_list) == "table" and empty_created_list.count == 0)

end
