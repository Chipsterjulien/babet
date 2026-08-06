return function(test, context)
    local _ENV = test:environment(context)
    local create_source = context.create_source
    local worker_create_code = [[
local result, err = babet.archive.create(worker.args.source, worker.args.destination)
if not result then error(err) end
return result.files
]]
    local create_worker_a, create_worker_a_err = babet.workers.spawn(
        worker_create_code,
        { source = create_source, destination = root .. "/worker-a.zip" })
    local create_worker_b, create_worker_b_err = babet.workers.spawn(
        worker_create_code,
        { source = create_source, destination = root .. "/worker-b.zip" })
    ok("archive.create starts safely in concurrent workers",
        create_worker_a ~= nil and create_worker_a_err == nil
        and create_worker_b ~= nil and create_worker_b_err == nil)
    local worker_a_ok, worker_a_files = create_worker_a:join()
    local worker_b_ok, worker_b_files = create_worker_b:join()
    ok("archive.create succeeds concurrently in worker states",
        worker_a_ok == true and worker_a_files == 3
        and worker_b_ok == true and worker_b_files == 3)
    ok("concurrent deterministic archive.create outputs are identical",
        read_bytes(root .. "/worker-a.zip") == read_bytes(root .. "/worker-b.zip"))

    local created_zip = root .. "/created.zip"
    local created, created_err = babet.archive.create(
        create_source, created_zip)
    ok_val("archive.create creates a ZIP from a directory",
        created, created_err, function(value)
            return value.files == 3 and value.directories == 2
                and value.bytes == 6 + 5 + #(string.rep("compress-me-", 2048))
                and value.sources == 1
                and value.path == created_zip
                and value.format == "zip"
                and value.compression == "none"
                and value.compression_level == 6
                and value.deterministic == true
        end)
    ok("archive.create publishes the destination", babet.isFile(created_zip) == true)
    local created_mode, created_mode_err = babet.getMode(created_zip)
    ok("archive.create publishes archives with mode 0644",
        created_mode == tonumber("644", 8) and created_mode_err == nil,
        tostring(created_mode_err))

    local created_list, created_list_err = babet.archive.list(created_zip)
    ok_val("archive.create output is readable by archive.list",
        created_list, created_list_err,
        function(value) return value.count == 5 end)
    ok("archive.create orders entries deterministically",
        created_list
        and created_list.entries[1].name == "alpha.txt"
        and created_list.entries[2].name == "nested/"
        and created_list.entries[3].name == "nested/binary.bin"
        and created_list.entries[4].name == "nested/empty/"
        and created_list.entries[5].name == "nested/repeated.txt")
    ok("archive.create does not copy source permission metadata",
        created_list and created_list.entries[1].unix_mode == nil)
    ok("archive.create uses DEFLATE by default for compressible files",
        created_list and created_list.entries[5].compression_method == 8,
        tostring(created_list and created_list.entries[5].compression_method))
    local created_raw = read_bytes(created_zip)
    local dos_time_lo, dos_time_hi, dos_date_lo, dos_date_hi
    if created_raw then
        dos_time_lo, dos_time_hi, dos_date_lo, dos_date_hi =
            string.byte(created_raw, 11, 14)
    end
    ok("archive.create deterministic timestamp is timezone-independent",
        dos_time_lo == 0 and dos_time_hi == 0
        and dos_date_lo == 33 and dos_date_hi == 0,
        string.format("%s,%s,%s,%s", tostring(dos_time_lo),
            tostring(dos_time_hi), tostring(dos_date_lo),
            tostring(dos_date_hi)))

    local create_roundtrip = root .. "/create-roundtrip"
    local roundtrip, roundtrip_err = babet.archive.extract(
        created_zip, create_roundtrip)
    ok_val("archive.create output extracts successfully", roundtrip, roundtrip_err)
    ok("archive.create round-trip preserves text",
        read_bytes(create_roundtrip .. "/alpha.txt") == "alpha\n")
    ok("archive.create round-trip preserves binary bytes",
        read_bytes(create_roundtrip .. "/nested/binary.bin") == "A\0B\255C")
    ok("archive.create round-trip preserves empty directories",
        babet.isDir(create_roundtrip .. "/nested/empty") == true)
end
