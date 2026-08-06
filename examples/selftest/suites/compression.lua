return function(test, context)
    local _ENV = test:environment(context)
-- =====================================================================
print("")
print("=== standalone compression streams ===")

do
    local root = sb("compression")
    babet.rmdirAll(root)
    assert(babet.mkdir(root))

    local function write_bytes(path, data)
        local file, open_err = io.open(path, "wb")
        if not file then return nil, open_err end
        local wrote, write_err = file:write(data)
        local closed, close_err = file:close()
        if not wrote then return nil, write_err end
        if closed == nil then return nil, close_err end
        return true
    end

    local function read_bytes(path)
        local file, open_err = io.open(path, "rb")
        if not file then return nil, open_err end
        local data = file:read("a")
        local closed, close_err = file:close()
        if data == nil then return nil, "cannot read file" end
        if closed == nil then return nil, close_err end
        return data
    end

    local function no_compression_temporaries()
        local result = babet.exec("find", {
            root, "-name", ".babet-compression-*", "-print",
        }, { timeout = 5 })
        return type(result) == "table" and result.code == 0
            and result.stdout == ""
    end

    ok("compression submodule registered",
        type(babet.compression) == "table"
        and type(babet.compression.compress) == "function"
        and type(babet.compression.decompress) == "function")

    local compression_worker, compression_worker_err = babet.workers.spawn([[
        return type(babet.compression) == "table"
            and type(babet.compression.compress) == "function"
            and type(babet.compression.decompress) == "function"
    ]])
    ok_val("compression submodule registered in worker states",
        compression_worker, compression_worker_err)
    if compression_worker then
        local joined, available = compression_worker:join()
        ok("compression functions available in a worker",
            joined == true and available == true,
            "joined=" .. tostring(joined)
            .. " available=" .. tostring(available))
    end

    local payload = "Babet compression 2.7.0\n"
        .. string.rep("abc\0def\n", 8192)
        .. "fin\0"
    local source = root .. "/payload.bin"
    assert(write_bytes(source, payload))

    local formats = {
        { name = "gzip", suffix = ".gz", min_level = 0,
          max_level = 9, default_level = 6 },
        { name = "xz", suffix = ".xz", min_level = 0,
          max_level = 9, default_level = 6 },
        { name = "bzip2", suffix = ".bz2", min_level = 1,
          max_level = 9, default_level = 9 },
        { name = "zstd", suffix = ".zst", min_level = 1,
          max_level = 22, default_level = 3 },
    }

    for _, format in ipairs(formats) do
        local compressed = root .. "/payload" .. format.suffix
        local restored = root .. "/restored-" .. format.name .. ".bin"

        local compressed_ok, compressed_err = babet.compression.compress(
            source, compressed, format.name)
        ok_act("compression.compress round-trip source (" .. format.name .. ")",
            compressed_ok, compressed_err)

        local restored_ok, restored_err = babet.compression.decompress(
            compressed, restored, { max_output_size = #payload })
        ok_act("compression.decompress auto-detects " .. format.name,
            restored_ok, restored_err)
        local restored_data, restored_read_err = read_bytes(restored)
        ok("compression " .. format.name .. " preserves binary bytes",
            restored_data == payload,
            restored_read_err or ("size=" .. tostring(restored_data and #restored_data)))

        local concat_a_source = root .. "/concat-a.bin"
        local concat_b_source = root .. "/concat-b.bin"
        assert(write_bytes(concat_a_source, "left\0"))
        assert(write_bytes(concat_b_source, "right"))
        local concat_a = root .. "/concat-a-" .. format.name
        local concat_b = root .. "/concat-b-" .. format.name
        assert(babet.compression.compress(
            concat_a_source, concat_a, format.name))
        assert(babet.compression.compress(
            concat_b_source, concat_b, format.name))
        local concatenated = root .. "/concatenated-" .. format.name
        assert(write_bytes(concatenated,
            assert(read_bytes(concat_a)) .. assert(read_bytes(concat_b))))
        local concatenated_out = concatenated .. ".out"
        local concatenated_ok, concatenated_err =
            babet.compression.decompress(concatenated, concatenated_out, {
                max_output_size = 10,
            })
        ok("compression accepts concatenated " .. format.name .. " members",
            concatenated_ok == true and concatenated_err == nil
            and read_bytes(concatenated_out) == "left\0right",
            "err=" .. tostring(concatenated_err))

        local duplicate_ok, duplicate_err = babet.compression.compress(
            source, compressed, format.name)
        ok_fail("compression refuses an existing destination ("
            .. format.name .. ")", duplicate_ok, duplicate_err)

        local overwrite_ok, overwrite_err = babet.compression.compress(
            source, compressed, format.name, { overwrite = true })
        ok_act("compression overwrite=true replaces atomically ("
            .. format.name .. ")", overwrite_ok, overwrite_err)

        babet.remove(restored)
        local limited_ok, limited_err = babet.compression.decompress(
            compressed, restored, { max_output_size = #payload - 1 })
        ok_fail("compression enforces max_output_size ("
            .. format.name .. ")", limited_ok, limited_err)
        local limited_exists = babet.fileExists(restored)
        ok("compression limit leaves no destination (" .. format.name .. ")",
            limited_exists == false)

        local encoded = assert(read_bytes(compressed))
        local truncated = root .. "/truncated-" .. format.name
        assert(write_bytes(truncated, encoded:sub(1, -2)))
        local truncated_out = root .. "/truncated-out-" .. format.name
        local truncated_ok, truncated_err = babet.compression.decompress(
            truncated, truncated_out)
        ok_fail("compression rejects truncated " .. format.name .. " streams",
            truncated_ok, truncated_err)
        ok("truncated " .. format.name .. " leaves no output",
            babet.fileExists(truncated_out) == false)

        local trailing = root .. "/trailing-" .. format.name
        assert(write_bytes(trailing, encoded .. "junk"))
        local trailing_out = root .. "/trailing-out-" .. format.name
        local trailing_ok, trailing_err = babet.compression.decompress(
            trailing, trailing_out)
        ok_fail("compression rejects trailing data after "
            .. format.name, trailing_ok, trailing_err)
        ok("trailing-data failure leaves no output (" .. format.name .. ")",
            babet.fileExists(trailing_out) == false)

        -- Corrupt format-specific integrity metadata rather than merely
        -- truncating the stream. Babet-generated zstd frames deliberately
        -- carry the optional content checksum.
        local corrupt_position
        if format.name == "gzip" then
            corrupt_position = #encoded - 7 -- CRC32 trailer
        elseif format.name == "xz" then
            corrupt_position = #encoded - 7 -- stream footer/check metadata
        elseif format.name == "bzip2" then
            corrupt_position = #encoded - 4 -- combined CRC/end marker
        else
            corrupt_position = #encoded -- zstd content checksum
        end
        local corrupted = encoded:sub(1, corrupt_position - 1)
            .. string.char(encoded:byte(corrupt_position) ~ 1)
            .. encoded:sub(corrupt_position + 1)
        local corrupt = root .. "/corrupt-" .. format.name
        assert(write_bytes(corrupt, corrupted))
        local corrupt_out = root .. "/corrupt-out-" .. format.name
        local corrupt_ok, corrupt_err = babet.compression.decompress(
            corrupt, corrupt_out)
        ok_fail("compression rejects corrupt " .. format.name
            .. " integrity data", corrupt_ok, corrupt_err)
        ok("corrupt " .. format.name .. " leaves no output",
            babet.fileExists(corrupt_out) == false)
    end

    -- Format-specific compression levels are strict Lua integers. The
    -- explicit default must be byte-for-byte identical to the implicit
    -- default, and each lowest accepted level must remain decodable.
    for _, format in ipairs(formats) do
        local implicit = root .. "/payload" .. format.suffix
        local explicit_default = root .. "/explicit-default-"
            .. format.name .. format.suffix
        local explicit_ok, explicit_err = babet.compression.compress(
            source, explicit_default, format.name, {
                level = format.default_level,
            })
        ok_act("compression accepts explicit default level ("
            .. format.name .. ")", explicit_ok, explicit_err)
        ok("compression default level is reproducible ("
            .. format.name .. ")",
            explicit_ok == true
            and read_bytes(explicit_default) == read_bytes(implicit))

        local lowest = root .. "/lowest-level-" .. format.name
            .. format.suffix
        local lowest_out = lowest .. ".out"
        local lowest_ok, lowest_err = babet.compression.compress(
            source, lowest, format.name, { level = format.min_level })
        local lowest_restore_ok, lowest_restore_err =
            babet.compression.decompress(lowest, lowest_out, {
                max_output_size = #payload,
            })
        ok("compression accepts and decodes the lowest " .. format.name
            .. " level",
            lowest_ok == true and lowest_err == nil
            and lowest_restore_ok == true and lowest_restore_err == nil
            and read_bytes(lowest_out) == payload,
            "compress_err=" .. tostring(lowest_err)
            .. " decompress_err=" .. tostring(lowest_restore_err))

        local boundary_ok, boundary_err = babet.compression.compress(
            root .. "/missing-source",
            root .. "/boundary-" .. format.name, format.name, {
                level = format.max_level,
            })
        ok("compression accepts the highest " .. format.name
            .. " level during validation",
            boundary_ok == nil and type(boundary_err) == "string"
            and boundary_err:find("source", 1, true) ~= nil
            and boundary_err:find("opts.level", 1, true) == nil,
            "err=" .. tostring(boundary_err))

        local below_ok, below_err = babet.compression.compress(
            source, root .. "/below-" .. format.name, format.name, {
                level = format.min_level - 1,
            })
        ok_fail("compression rejects a " .. format.name
            .. " level below the supported range", below_ok, below_err)
        ok("compression reports the lower " .. format.name
            .. " level bound",
            type(below_err) == "string"
            and below_err:find("opts.level for " .. format.name, 1, true)
                ~= nil
            and below_err:find(tostring(format.min_level), 1, true) ~= nil,
            "err=" .. tostring(below_err))

        local above_ok, above_err = babet.compression.compress(
            source, root .. "/above-" .. format.name, format.name, {
                level = format.max_level + 1,
            })
        ok_fail("compression rejects a " .. format.name
            .. " level above the supported range", above_ok, above_err)
        ok("compression reports the upper " .. format.name
            .. " level bound",
            type(above_err) == "string"
            and above_err:find(tostring(format.max_level), 1, true) ~= nil,
            "err=" .. tostring(above_err))
    end

    local empty = root .. "/empty.bin"
    assert(write_bytes(empty, ""))
    for _, format in ipairs(formats) do
        local compressed = empty .. format.suffix
        local restored = compressed .. ".out"
        local compressed_ok, compressed_err = babet.compression.compress(
            empty, compressed, format.name)
        local restored_ok, restored_err = babet.compression.decompress(
            compressed, restored, { max_output_size = 1 })
        local restored_data = restored_ok and read_bytes(restored) or nil
        ok("compression empty-file round-trip (" .. format.name .. ")",
            compressed_ok == true and compressed_err == nil
            and restored_ok == true and restored_err == nil
            and restored_data == "",
            "compress_err=" .. tostring(compressed_err)
            .. " decompress_err=" .. tostring(restored_err))
    end

    local unknown_ok, unknown_err = babet.compression.compress(
        source, root .. "/unknown", "zip")
    ok_fail("compression rejects an unknown format", unknown_ok, unknown_err)

    local plain_out = root .. "/plain.out"
    local plain_ok, plain_err = babet.compression.decompress(source, plain_out)
    ok_fail("compression rejects an uncompressed input", plain_ok, plain_err)
    ok("unrecognised input leaves no output",
        babet.fileExists(plain_out) == false)

    local same_ok, same_err = babet.compression.compress(
        source, source, "gzip", { overwrite = true })
    ok_fail("compression refuses identical source and destination",
        same_ok, same_err)
    ok("identical-path refusal preserves the source",
        read_bytes(source) == payload)

    local hardlink = root .. "/payload-hardlink"
    local hardlink_result = babet.exec("ln", { source, hardlink })
    assert(type(hardlink_result) == "table" and hardlink_result.code == 0)
    local hardlink_ok, hardlink_err = babet.compression.compress(
        source, hardlink, "gzip", { overwrite = true })
    ok_fail("compression refuses a destination hard-linked to the source",
        hardlink_ok, hardlink_err)
    ok("hard-link refusal preserves the source",
        read_bytes(source) == payload)

    local source_link = root .. "/source-link"
    assert(babet.link("payload.bin", source_link))
    local source_link_ok, source_link_err = babet.compression.compress(
        source_link, root .. "/source-link.gz", "gzip")
    ok_fail("compression refuses a symlink source",
        source_link_ok, source_link_err)

    local destination_target = root .. "/destination-target"
    assert(write_bytes(destination_target, "unchanged"))
    local destination_link = root .. "/destination-link"
    assert(babet.link("destination-target", destination_link))
    local destination_link_ok, destination_link_err =
        babet.compression.compress(source, destination_link, "gzip", {
            overwrite = true,
        })
    ok_fail("compression refuses a symlink destination",
        destination_link_ok, destination_link_err)
    ok("symlink destination target remains unchanged",
        read_bytes(destination_target) == "unchanged")

    local real_parent = root .. "/real-parent"
    assert(babet.mkdir(real_parent))
    local parent_link = root .. "/parent-link"
    assert(babet.link("real-parent", parent_link))
    local parent_link_ok, parent_link_err = babet.compression.compress(
        source, parent_link .. "/escape.gz", "gzip")
    ok_fail("compression refuses symlink components in destination parent",
        parent_link_ok, parent_link_err)
    ok("symlink-parent refusal creates no escaped file",
        babet.fileExists(real_parent .. "/escape.gz") == false)

    local source_parent_link = root .. "/source-parent-link"
    assert(babet.link(".", source_parent_link))
    local source_parent_ok, source_parent_err = babet.compression.compress(
        source_parent_link .. "/payload.bin",
        root .. "/source-parent.gz", "gzip")
    ok_fail("compression refuses symlink components in source parent",
        source_parent_ok, source_parent_err)

    local source_dotdot_ok, source_dotdot_err = babet.compression.compress(
        real_parent .. "/../payload.bin", root .. "/source-dotdot.gz",
        "gzip")
    ok_fail("compression refuses '..' in the source parent path",
        source_dotdot_ok, source_dotdot_err)
    local destination_dotdot_ok, destination_dotdot_err =
        babet.compression.compress(source,
            real_parent .. "/../destination-dotdot.gz", "gzip")
    ok_fail("compression refuses '..' in the destination parent path",
        destination_dotdot_ok, destination_dotdot_err)

    local directory_ok, directory_err = babet.compression.compress(
        root, root .. "/directory.gz", "gzip")
    ok_fail("compression source must be a regular file",
        directory_ok, directory_err)
    local destination_directory_ok, destination_directory_err =
        babet.compression.compress(source, real_parent, "gzip", {
            overwrite = true,
        })
    ok_fail("compression destination must be a regular file",
        destination_directory_ok, destination_directory_err)

    ok_raises("compression source is a strict string",
        function()
            return babet.compression.compress(42, root .. "/x.gz", "gzip")
        end, "string")
    ok_raises("compression destination is a strict string",
        function()
            return babet.compression.compress(source, 42, "gzip")
        end, "string")
    ok_raises("compression format is a strict string",
        function()
            return babet.compression.compress(source, root .. "/x.gz", 42)
        end, "string")
    ok_raises("compression rejects source NUL",
        function()
            return babet.compression.compress(
                source .. "\0ignored", root .. "/x.gz", "gzip")
        end, "NUL")
    ok_raises("compression.compress rejects excess arguments",
        function()
            return babet.compression.compress(
                source, root .. "/x.gz", "gzip", {}, "extra")
        end, "3 or 4 arguments")
    ok_raises("compression.decompress rejects excess arguments",
        function()
            return babet.compression.decompress(source, plain_out, {}, "extra")
        end, "2 or 3 arguments")

    local invalid_ok, invalid_err = babet.compression.compress(
        source, root .. "/invalid.gz", "gzip", "bad")
    ok_fail("compression opts must be a table", invalid_ok, invalid_err)
    invalid_ok, invalid_err = babet.compression.compress(
        source, root .. "/invalid.gz", "gzip", { overwrite = 1 })
    ok_fail("compression overwrite is a strict boolean",
        invalid_ok, invalid_err)
    invalid_ok, invalid_err = babet.compression.compress(
        source, root .. "/invalid.gz", "gzip", { level = 1.5 })
    ok_fail("compression level must be a Lua integer",
        invalid_ok, invalid_err)
    invalid_ok, invalid_err = babet.compression.compress(
        source, root .. "/invalid.gz", "gzip", { level = "6" })
    ok_fail("compression level rejects numeric strings",
        invalid_ok, invalid_err)
    invalid_ok, invalid_err = babet.compression.compress(
        source, root .. "/invalid.gz", "gzip", { unknown = true })
    ok_fail("compression rejects unknown options", invalid_ok, invalid_err)
    invalid_ok, invalid_err = babet.compression.compress(
        source, root .. "/invalid.gz", "gzip", { max_output_size = 1 })
    ok_fail("compression.compress rejects decompression-only options",
        invalid_ok, invalid_err)
    invalid_ok, invalid_err = babet.compression.decompress(
        root .. "/payload.gz", root .. "/invalid.out", { level = 6 })
    ok_fail("compression.decompress rejects compression-only options",
        invalid_ok, invalid_err)

    local sample_gzip = root .. "/payload.gz"

    local renamed_gzip = root .. "/payload-without-extension.bin"
    assert(write_bytes(renamed_gzip, assert(read_bytes(sample_gzip))))
    local renamed_out = root .. "/payload-without-extension.out"
    local renamed_ok, renamed_err = babet.compression.decompress(
        renamed_gzip, renamed_out, { max_output_size = #payload })
    ok("compression detection ignores the filename extension",
        renamed_ok == true and renamed_err == nil
        and read_bytes(renamed_out) == payload,
        "err=" .. tostring(renamed_err))

    local sample_mode, sample_mode_err = babet.getMode(sample_gzip)
    ok("compression publishes final files with mode 0644",
        sample_mode == tonumber("644", 8) and sample_mode_err == nil,
        "mode=" .. tostring(sample_mode)
        .. " err=" .. tostring(sample_mode_err))

    local preserved_after_failure = root .. "/preserved-after-failure.out"
    assert(write_bytes(preserved_after_failure, "sentinel"))
    local failed_overwrite, failed_overwrite_err =
        babet.compression.decompress(root .. "/truncated-gzip",
            preserved_after_failure, { overwrite = true })
    ok_fail("failed decompression preserves an overwritten destination",
        failed_overwrite, failed_overwrite_err)
    ok("failed overwrite leaves the previous destination bytes unchanged",
        read_bytes(preserved_after_failure) == "sentinel")

    invalid_ok, invalid_err = babet.compression.decompress(
        sample_gzip, root .. "/invalid.out", { max_output_size = 1.5 })
    ok_fail("compression max_output_size must be a Lua integer",
        invalid_ok, invalid_err)
    invalid_ok, invalid_err = babet.compression.decompress(
        sample_gzip, root .. "/invalid.out", { max_output_size = 0 })
    ok_fail("compression rejects max_output_size zero",
        invalid_ok, invalid_err)
    invalid_ok, invalid_err = babet.compression.decompress(
        sample_gzip, root .. "/invalid.out", {
            max_output_size = 68719476737,
        })
    ok_fail("compression rejects max_output_size above 64 GiB",
        invalid_ok, invalid_err)

    ok("compression leaves no staging files",
        no_compression_temporaries())

    babet.rmdirAll(root)
end
end
