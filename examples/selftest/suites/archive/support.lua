return function(test, context)
    local _ENV = test:environment(context)
    local root = sb("archive")
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

    local function crc32_number(data)
        return assert(tonumber(babet.crc32(data), 16))
    end

    local function zip_mode(type_bits, permissions)
        return ((type_bits | permissions) & 0xffff) << 16
    end

    local function make_zip(path, entries)
        local local_parts = {}
        local central_parts = {}
        local local_offset = 0
        local dos_time = 0
        local dos_date = 0x21 -- 1980-01-01

        for _, entry in ipairs(entries) do
            local name = assert(entry.name)
            local data = entry.data or ""
            local payload = entry.payload or data
            local entry_dos_time = entry.dos_time or dos_time
            local entry_dos_date = entry.dos_date or dos_date
            local method = entry.method
            if method == nil then method = entry.payload and 8 or 0 end
            local flags = entry.flags or 0
            local crc = entry.crc32
            if crc == nil then crc = crc32_number(data) end
            local compressed_size = entry.compressed_size or #payload
            local expanded_size = entry.size or #data
            local version_made_by = entry.version_made_by or ((3 << 8) | 20)
            local external = entry.external_attributes
            if external == nil then
                if name:sub(-1) == "/" then
                    external = zip_mode(0x4000, entry.permissions or tonumber("755", 8)) | 0x10
                else
                    external = zip_mode(0x8000, entry.permissions or tonumber("644", 8))
                end
            end

            local local_name = entry.local_name or name
            local local_extra = entry.local_extra or ""
            local local_flags = entry.local_flags
            if local_flags == nil then local_flags = flags end
            local local_method = entry.local_method
            if local_method == nil then local_method = method end
            local local_crc = entry.local_crc32
            if local_crc == nil then local_crc = crc end
            local local_compressed_size = entry.local_compressed_size
            if local_compressed_size == nil then
                local_compressed_size = compressed_size
            end
            local local_expanded_size = entry.local_size
            if local_expanded_size == nil then local_expanded_size = expanded_size end
            local local_header = string.pack(
                "<I4I2I2I2I2I2I4I4I4I2I2",
                entry.local_signature or 0x04034b50, 20,
                local_flags, local_method,
                entry_dos_time, entry_dos_date,
                local_crc, local_compressed_size, local_expanded_size,
                #local_name, #local_extra)
            local local_record = local_header .. local_name .. local_extra
                .. payload .. (entry.descriptor or "")
            local_parts[#local_parts + 1] = local_record

            local central_header = string.pack(
                "<I4I2I2I2I2I2I2I4I4I4I2I2I2I2I2I4I4",
                0x02014b50, version_made_by, 20, flags, method,
                entry_dos_time, entry_dos_date,
                crc, compressed_size, expanded_size,
                #name, 0, 0, entry.disk_start or 0, 0,
                external, local_offset)
            central_parts[#central_parts + 1] = central_header .. name
            local_offset = local_offset + #local_record
        end

        local local_blob = table.concat(local_parts)
        local central_blob = table.concat(central_parts)
        local eocd = string.pack(
            "<I4I2I2I2I2I4I4I2",
            0x06054b50, 0, 0, #entries, #entries,
            #central_blob, #local_blob, 0)
        return write_bytes(path, local_blob .. central_blob .. eocd)
    end

    local function make_empty_zip64(path, opts)
        opts = opts or {}
        local zip64_eocd = string.pack(
            "<I4I8I2I2I4I4I8I8I8I8",
            0x06064b50, 44, 45, 45,
            opts.disk_number or 0,
            opts.central_directory_disk or 0,
            opts.entries_on_disk or 0,
            opts.total_entries or 0,
            0, 0)
        local locator = string.pack(
            "<I4I4I8I4", 0x07064b50,
            opts.locator_disk or 0, 0, opts.total_disks or 1)
        local eocd = string.pack(
            "<I4I2I2I2I2I4I4I2",
            0x06054b50, 0, 0, 0xffff, 0xffff,
            0xffffffff, 0xffffffff, 0)
        return write_bytes(path, zip64_eocd .. locator .. eocd)
    end

    local function tar_text_field(value, width)
        value = value or ""
        assert(#value <= width, "TAR field is too long")
        return value .. string.rep("\0", width - #value)
    end

    local function tar_octal_field(value, width)
        value = value or 0
        local digits = string.format("%0" .. tostring(width - 1) .. "o", value)
        assert(#digits <= width - 1, "TAR octal field is too large")
        return digits .. "\0"
    end

    local function tar_name_fields(name)
        if #name <= 100 then return name, "" end
        for i = #name, 1, -1 do
            if name:sub(i, i) == "/" then
                local prefix = name:sub(1, i - 1)
                local leaf = name:sub(i + 1)
                if #prefix <= 155 and #leaf <= 100 and #leaf > 0 then
                    return leaf, prefix
                end
            end
        end
        error("TAR path does not fit in a ustar header: " .. name)
    end

    local function tar_header(entry)
        local name, prefix = tar_name_fields(assert(entry.name))
        local typeflag = entry.typeflag or "0"
        local data = entry.data or ""
        local size = entry.size
        if size == nil then
            size = (typeflag == "0" or typeflag == "\0" or typeflag == "x"
                or typeflag == "L") and #data or 0
        end

        local header = table.concat({
            tar_text_field(name, 100),
            tar_octal_field(entry.mode or tonumber("644", 8), 8),
            tar_octal_field(entry.uid or 0, 8),
            tar_octal_field(entry.gid or 0, 8),
            tar_octal_field(size, 12),
            tar_octal_field(entry.mtime or 0, 12),
            string.rep(" ", 8),
            typeflag,
            tar_text_field(entry.linkname, 100),
            "ustar\0",
            "00",
            tar_text_field(entry.uname or "root", 32),
            tar_text_field(entry.gname or "root", 32),
            tar_octal_field(entry.devmajor or 0, 8),
            tar_octal_field(entry.devminor or 0, 8),
            tar_text_field(prefix, 155),
            string.rep("\0", 12),
        })
        assert(#header == 512)

        local checksum = 0
        for i = 1, #header do checksum = checksum + header:byte(i) end
        local encoded_checksum = string.format("%06o\0 ", checksum)
        assert(#encoded_checksum == 8)
        header = header:sub(1, 148) .. encoded_checksum .. header:sub(157)
        return header, data, size
    end

    local function pax_record(key, value)
        local body = key .. "=" .. value .. "\n"
        local length = #body + 2
        while true do
            local record = tostring(length) .. " " .. body
            if #record == length then return record end
            length = #record
        end
    end

    local function make_tar(path, entries, opts)
        opts = opts or {}
        local parts = {}

        local function emit(entry)
            local header, data, size = tar_header(entry)
            parts[#parts + 1] = header
            parts[#parts + 1] = data
            local padding = (512 - (size % 512)) % 512
            if padding > 0 then
                parts[#parts + 1] = string.rep("\0", padding)
            end
        end

        for index, source_entry in ipairs(entries) do
            local entry = {}
            for key, value in pairs(source_entry) do entry[key] = value end

            if source_entry.gnu_longname then
                emit({
                    name = "././@LongLink",
                    typeflag = "L",
                    mode = tonumber("644", 8),
                    data = source_entry.name .. "\0",
                })
                entry.name = "gnu-long-name-" .. tostring(index)
                entry.gnu_longname = nil
            elseif source_entry.pax_path then
                emit({
                    name = "PaxHeader/path-" .. tostring(index),
                    typeflag = "x",
                    mode = tonumber("644", 8),
                    data = pax_record("path", source_entry.name),
                })
                entry.name = "pax-path-" .. tostring(index)
                entry.pax_path = nil
            end
            emit(entry)
        end

        if not opts.omit_end_blocks then
            parts[#parts + 1] = string.rep("\0", 1024)
        end
        return write_bytes(path, table.concat(parts))
    end

    local function make_old_gnu_sparse_tar(path)
        local sparse_descriptor = tar_octal_field(1024, 12)
            .. tar_octal_field(4, 12)
        local empty_descriptor = tar_octal_field(0, 12)
            .. tar_octal_field(0, 12)
        local header = table.concat({
            tar_text_field("sparse.bin", 100),
            tar_octal_field(tonumber("644", 8), 8),
            tar_octal_field(0, 8),
            tar_octal_field(0, 8),
            tar_octal_field(4, 12), -- condensed payload size
            tar_octal_field(0, 12),
            string.rep(" ", 8),
            "S", -- old GNU sparse regular file
            tar_text_field("", 100),
            "ustar  \0",
            tar_text_field("root", 32),
            tar_text_field("root", 32),
            tar_octal_field(0, 8),
            tar_octal_field(0, 8),
            tar_octal_field(0, 12), -- atime
            tar_octal_field(0, 12), -- ctime
            tar_octal_field(0, 12), -- legacy offset field
            string.rep("\0", 4),
            "\0",
            sparse_descriptor,
            empty_descriptor,
            empty_descriptor,
            empty_descriptor,
            "\0", -- no extended sparse map block
            tar_octal_field(2048, 12), -- expanded size
            string.rep("\0", 17),
        })
        assert(#header == 512)
        local checksum = 0
        for i = 1, #header do checksum = checksum + header:byte(i) end
        local encoded_checksum = string.format("%06o\0 ", checksum)
        header = header:sub(1, 148) .. encoded_checksum .. header:sub(157)
        return write_bytes(path,
            header .. "DATA" .. string.rep("\0", 508)
            .. string.rep("\0", 1024))
    end

    local function no_archive_temporaries(path)
        local result = babet.exec("find", {
            path, "-name", ".babet-archive-*", "-print",
        }, { timeout = 5 })
        return type(result) == "table" and result.code == 0
            and result.stdout == ""
    end

    local deflated_4096_a =
        "\xED\xC1\x01\x0D\x00\x00\x00\xC2\xA0\x6C\xEF\x5F" ..
        "\xCA\x1E\x0E\x28\x00\x00\x00\xE0\xDD\x00"

    ok("archive submodule registered",
        type(babet.archive) == "table"
        and type(babet.archive.create) == "function"
        and type(babet.archive.list) == "function"
        and type(babet.archive.test) == "function"
        and type(babet.archive.extract) == "function"
        and type(babet.archive.extractFile) == "function"
        and type(babet.archive.read) == "function")

    return {
        root = root,
        write_bytes = write_bytes,
        read_bytes = read_bytes,
        crc32_number = crc32_number,
        zip_mode = zip_mode,
        make_zip = make_zip,
        make_empty_zip64 = make_empty_zip64,
        tar_text_field = tar_text_field,
        tar_octal_field = tar_octal_field,
        tar_name_fields = tar_name_fields,
        tar_header = tar_header,
        pax_record = pax_record,
        make_tar = make_tar,
        make_old_gnu_sparse_tar = make_old_gnu_sparse_tar,
        no_archive_temporaries = no_archive_temporaries,
        deflated_4096_a = deflated_4096_a,
    }
end
