return function(test, context)
    local _ENV = test:environment(context)
    local create_source = context.create_source
    do
    -- archive.create explicit source lists (2.7.0 lot 3) --------------
    local list_a = root .. "/list-a"
    local list_b = root .. "/list-b"
    assert(babet.mkdir(list_a))
    assert(babet.mkdir(list_b .. "/nested"))
    assert(write_bytes(list_a .. "/report.txt", "report"))
    assert(write_bytes(list_b .. "/root.txt", "root"))
    assert(write_bytes(list_b .. "/nested/data.bin", "A\0B"))

    local explicit_sources = {
        list_a .. "/report.txt",
        list_b .. "/", -- trailing slash keeps the stable basename list-b
    }
    local explicit_zip = root .. "/explicit-list.zip"
    local explicit, explicit_err = babet.archive.create(
        explicit_sources, explicit_zip)
    ok_val("archive.create accepts an explicit file/directory source list",
        explicit, explicit_err, function(value)
            return value.sources == 2 and value.files == 3
                and value.directories == 2 and value.bytes == 13
                and value.format == "zip"
        end)

    local explicit_meta_called = false
    local explicit_sources_with_meta = setmetatable({
        list_a .. "/report.txt",
        list_b .. "/",
    }, {
        __len = function()
            explicit_meta_called = true
            error("archive.create must not invoke __len")
        end,
        __index = function()
            explicit_meta_called = true
            error("archive.create must not invoke __index")
        end,
    })
    local explicit_meta, explicit_meta_err = babet.archive.create(
        explicit_sources_with_meta, root .. "/explicit-list-meta.zip")
    ok_val("archive.create reads explicit sources without metamethods",
        explicit_meta, explicit_meta_err, function(value)
            return explicit_meta_called == false and value.sources == 2
                and value.files == 3 and value.directories == 2
        end)
    local explicit_list, explicit_list_err = babet.archive.list(explicit_zip)
    ok_val("archive.create explicit-list ZIP is readable",
        explicit_list, explicit_list_err)
    local explicit_names = {}
    if explicit_list then
        for _, item in ipairs(explicit_list.entries) do
            explicit_names[item.name] = true
        end
    end
    ok("explicit sources use deterministic top-level basenames",
        explicit_names["report.txt"] == true
        and explicit_names["list-b/"] == true
        and explicit_names["list-b/root.txt"] == true
        and explicit_names["list-b/nested/"] == true
        and explicit_names["list-b/nested/data.bin"] == true)

    local explicit_out = root .. "/explicit-list-out"
    local explicit_extracted, explicit_extract_err = babet.archive.extract(
        explicit_zip, explicit_out)
    ok_val("explicit-list ZIP extracts successfully",
        explicit_extracted, explicit_extract_err)
    ok("explicit-list extraction preserves unrelated sources",
        read_bytes(explicit_out .. "/report.txt") == "report"
        and read_bytes(explicit_out .. "/list-b/root.txt") == "root"
        and read_bytes(explicit_out .. "/list-b/nested/data.bin") == "A\0B")

    local single_directory_zip = root .. "/single-directory-list.zip"
    local single_directory, single_directory_err = babet.archive.create(
        { list_b }, single_directory_zip)
    ok_val("a directory in an explicit list keeps its basename",
        single_directory, single_directory_err,
        function(value) return value.sources == 1 and value.files == 2 end)
    local single_directory_list = babet.archive.list(single_directory_zip)
    ok("explicit-list directory root differs deliberately from legacy mode",
        single_directory_list and single_directory_list.entries[1]
        and single_directory_list.entries[1].name == "list-b/")

    local no_directory_entries = root .. "/explicit-no-directories.zip"
    local no_directories, no_directories_err = babet.archive.create(
        explicit_sources, no_directory_entries,
        { include_directories = false })
    ok_val("explicit source lists support include_directories=false",
        no_directories, no_directories_err,
        function(value) return value.files == 3 and value.directories == 0 end)
    local no_directories_list = babet.archive.list(no_directory_entries)
    ok("explicit-list files retain directory prefixes without directory entries",
        no_directories_list and no_directories_list.count == 3
        and no_directories_list.entries[1].name == "list-b/nested/data.bin"
        and no_directories_list.entries[2].name == "list-b/root.txt"
        and no_directories_list.entries[3].name == "report.txt")

    local explicit_tar = root .. "/explicit-list.tar"
    local explicit_tar_result, explicit_tar_err = babet.archive.create(
        explicit_sources, explicit_tar)
    ok_val("explicit source lists work with TAR backends",
        explicit_tar_result, explicit_tar_err,
        function(value)
            return value.sources == 2 and value.format == "tar"
                and value.compression == "none"
        end)
    local explicit_tar_list = babet.archive.list(explicit_tar)
    ok("explicit-list TAR preserves the same entry names",
        explicit_tar_list and explicit_tar_list.count == 5
        and explicit_tar_list.entries[1].name == "list-b/")

    local explicit_order_a = root .. "/explicit-order-a.zip"
    local explicit_order_b = root .. "/explicit-order-b.zip"
    local order_a, order_a_err = babet.archive.create(
        { list_a .. "/report.txt", list_b }, explicit_order_a)
    local order_b, order_b_err = babet.archive.create(
        { list_b, list_a .. "/report.txt" }, explicit_order_b)
    ok_val("explicit-list deterministic fixture A", order_a, order_a_err)
    ok_val("explicit-list deterministic fixture B", order_b, order_b_err)
    ok("explicit-list output is independent of source-list order",
        read_bytes(explicit_order_a) == read_bytes(explicit_order_b))

    local absolute_report = startDir .. "/" .. list_a .. "/report.txt"
    local absolute_zip = root .. "/explicit-absolute.zip"
    local absolute_result, absolute_err = babet.archive.create(
        { absolute_report }, absolute_zip)
    ok_val("explicit source lists accept absolute paths",
        absolute_result, absolute_err,
        function(value) return value.sources == 1 and value.files == 1 end)
    local absolute_list = babet.archive.list(absolute_zip)
    ok("absolute explicit sources never leak host path components",
        absolute_list and absolute_list.count == 1
        and absolute_list.entries[1].name == "report.txt")

    local explicit_worker_code = [[
local result, err = babet.archive.create(
    worker.args.sources, worker.args.destination)
if not result then error(err) end
return result.sources
]]
    local explicit_worker = babet.workers.spawn(explicit_worker_code, {
        sources = explicit_sources,
        destination = root .. "/explicit-worker.zip",
    })
    ok("explicit source list starts safely in a worker",
        explicit_worker ~= nil)
    local explicit_worker_ok, explicit_worker_sources = false, nil
    if explicit_worker then
        explicit_worker_ok, explicit_worker_sources = explicit_worker:join()
    end
    ok("explicit source list succeeds in a worker",
        explicit_worker_ok == true and explicit_worker_sources == 2)

    local collision_a = root .. "/collision-a"
    local collision_b = root .. "/collision-b"
    assert(babet.mkdir(collision_a))
    assert(babet.mkdir(collision_b))
    assert(write_bytes(collision_a .. "/same.txt", "a"))
    assert(write_bytes(collision_b .. "/same.txt", "b"))
    local collision_path = root .. "/explicit-collision.zip"
    local collision, collision_err = babet.archive.create({
        collision_a .. "/same.txt",
        collision_b .. "/same.txt",
    }, collision_path)
    ok_fail("explicit source lists reject colliding top-level basenames",
        collision, collision_err)
    ok("explicit-list collision failure leaves no output",
        babet.fileExists(collision_path) == false)

    local duplicate_path = root .. "/explicit-duplicate.zip"
    local duplicate, duplicate_err = babet.archive.create({
        list_a .. "/report.txt",
        list_a .. "/report.txt",
    }, duplicate_path)
    ok_fail("explicit source lists reject duplicate source entries",
        duplicate, duplicate_err)
    ok("explicit-list duplicate failure leaves no output",
        babet.fileExists(duplicate_path) == false)

    local empty_list, empty_list_err = babet.archive.create(
        {}, root .. "/explicit-empty.zip")
    ok_fail("archive.create rejects an empty explicit source list",
        empty_list, empty_list_err)
    local sparse_list, sparse_list_err = babet.archive.create(
        { [2] = list_b }, root .. "/explicit-sparse.zip")
    ok_fail("archive.create requires a dense explicit source list",
        sparse_list, sparse_list_err)
    local keyed_list, keyed_list_err = babet.archive.create(
        { list_b, extra = list_a }, root .. "/explicit-keyed.zip")
    ok_fail("archive.create rejects non-array keys in explicit sources",
        keyed_list, keyed_list_err)
    local typed_list, typed_list_err = babet.archive.create(
        { list_b, 42 }, root .. "/explicit-typed.zip")
    ok_fail("archive.create explicit sources require strict strings",
        typed_list, typed_list_err)
    local nul_list, nul_list_err = babet.archive.create(
        { list_b .. "\0ignored" }, root .. "/explicit-nul.zip")
    ok_fail("archive.create rejects NUL in explicit source paths",
        nul_list, nul_list_err)
    local blank_list, blank_list_err = babet.archive.create(
        { "" }, root .. "/explicit-blank.zip")
    ok_fail("archive.create rejects empty explicit source paths",
        blank_list, blank_list_err)
    local unstable_name, unstable_name_err = babet.archive.create(
        { "." }, root .. "/explicit-dot.zip")
    ok_fail("archive.create requires stable explicit top-level names",
        unstable_name, unstable_name_err)
    local root_source, root_source_err = babet.archive.create(
        { "/" }, root .. "/explicit-root.zip")
    ok_fail("archive.create rejects filesystem root as an explicit source",
        root_source, root_source_err)
    local dotdot_list, dotdot_list_err = babet.archive.create(
        { root .. "/other/../list-b" }, root .. "/explicit-dotdot.zip")
    ok_fail("archive.create rejects '..' in explicit source paths",
        dotdot_list, dotdot_list_err)
    local missing_list, missing_list_err = babet.archive.create(
        { root .. "/missing-explicit" }, root .. "/explicit-missing.zip")
    ok_fail("archive.create rejects missing explicit sources",
        missing_list, missing_list_err)

    local explicit_link = root .. "/explicit-source-link"
    local make_explicit_link = babet.exec("ln", { "-s", "list-b", explicit_link })
    ok("explicit source symlink fixture created",
        type(make_explicit_link) == "table" and make_explicit_link.code == 0)
    local linked_list, linked_list_err = babet.archive.create(
        { explicit_link }, root .. "/explicit-link.zip")
    ok_fail("archive.create rejects symlinks in explicit source lists",
        linked_list, linked_list_err)

    local explicit_parent_target = root .. "/explicit-parent-target"
    assert(babet.mkdir(explicit_parent_target))
    assert(write_bytes(explicit_parent_target .. "/inside.txt", "inside"))
    local explicit_parent_link = root .. "/explicit-parent-link"
    assert(babet.exec("ln", {
        "-s", "explicit-parent-target", explicit_parent_link,
    }).code == 0)
    local linked_parent_list, linked_parent_list_err = babet.archive.create(
        { explicit_parent_link .. "/inside.txt" },
        root .. "/explicit-parent-link.zip")
    ok_fail("archive.create rejects symlink components in explicit paths",
        linked_parent_list, linked_parent_list_err)

    local explicit_fifo = root .. "/explicit-fifo"
    assert(babet.exec("mkfifo", { explicit_fifo }).code == 0)
    local fifo_list, fifo_list_err = babet.archive.create(
        { explicit_fifo }, root .. "/explicit-fifo.zip")
    ok_fail("archive.create rejects unsupported explicit source types",
        fifo_list, fifo_list_err)
    babet.exec("rm", { "-f", explicit_fifo })

    local inside_explicit, inside_explicit_err = babet.archive.create(
        { list_b }, list_b .. "/inside-explicit.zip")
    ok_fail("archive.create refuses output inside an explicit directory source",
        inside_explicit, inside_explicit_err)
    ok("explicit inside-source refusal leaves no output",
        babet.fileExists(list_b .. "/inside-explicit.zip") == false)

    local list_limit, list_limit_err = babet.archive.create(
        explicit_sources, root .. "/explicit-limit.zip", { max_entries = 4 })
    ok_fail("archive.create applies max_entries across explicit sources",
        list_limit, list_limit_err)
    local list_total_limit, list_total_limit_err = babet.archive.create(
        explicit_sources, root .. "/explicit-total-limit.zip",
        { max_total_size = 12 })
    ok_fail("archive.create applies max_total_size across explicit sources",
        list_total_limit, list_total_limit_err)

    local invalid_top_name = root .. "/explicit-invalid-\255.txt"
    assert(write_bytes(invalid_top_name, "invalid"))
    local invalid_top, invalid_top_err = babet.archive.create(
        { invalid_top_name }, root .. "/explicit-invalid-name.zip")
    ok_fail("archive.create rejects invalid UTF-8 explicit top-level names",
        invalid_top, invalid_top_err)
    babet.remove(invalid_top_name)

    ;(function()
    -- archive.create include/exclude safe globs (2.7.0 lot 4) ---------
    local filter_source = root .. "/filter-source"
    assert(babet.mkdir(filter_source .. "/src/private"))
    assert(babet.mkdir(filter_source .. "/src/empty"))
    assert(babet.mkdir(filter_source .. "/docs"))
    assert(babet.mkdir(filter_source .. "/cache"))
    assert(write_bytes(filter_source .. "/top.txt", "top"))
    assert(write_bytes(filter_source .. "/top.log", "log"))
    assert(write_bytes(filter_source .. "/literal*.dat", "literal"))
    assert(write_bytes(filter_source .. "/src/main.lua", "return 1"))
    assert(write_bytes(filter_source .. "/src/util.cpp", "int x;"))
    assert(write_bytes(filter_source .. "/src/private/secret.lua", "secret"))
    assert(write_bytes(filter_source .. "/docs/readme.md", "readme"))
    assert(write_bytes(filter_source .. "/docs/draft.tmp", "draft"))
    assert(write_bytes(filter_source .. "/cache/data.bin", "cache"))

    local function archive_name_set(path)
        local info, info_err = babet.archive.list(path)
        if not info then return nil, info_err end
        local set = {}
        for _, item in ipairs(info.entries) do set[item.name] = true end
        return set, info
    end

    local selected_zip = root .. "/filtered-selected.zip"
    local selected, selected_err = babet.archive.create(
        filter_source, selected_zip, {
            include = { "src/*.lua", "docs/**" },
            exclude = { "docs/*.tmp" },
        })
    ok_val("archive.create accepts bounded include/exclude globs",
        selected, selected_err, function(value)
            return value.files == 2 and value.directories == 2
                and value.include_patterns == 2
                and value.exclude_patterns == 1
        end)
    local selected_names, selected_info = archive_name_set(selected_zip)
    ok("include patterns match complete archive paths and '*' stays in one component",
        selected_names and selected_info.count == 4
        and selected_names["docs/"] == true
        and selected_names["docs/readme.md"] == true
        and selected_names["src/"] == true
        and selected_names["src/main.lua"] == true
        and selected_names["src/private/secret.lua"] ~= true
        and selected_names["docs/draft.tmp"] ~= true)

    local parent_zip = root .. "/filtered-parent.zip"
    local parent_result, parent_err = babet.archive.create(
        filter_source, parent_zip, {
            include = { "src/private/secret.lua" },
        })
    ok_val("included deep files retain required parent directory entries",
        parent_result, parent_err,
        function(value) return value.files == 1 and value.directories == 2 end)
    local parent_names, parent_info = archive_name_set(parent_zip)
    ok("only the selected deep file and its parents are emitted",
        parent_names and parent_info.count == 3
        and parent_names["src/"] == true
        and parent_names["src/private/"] == true
        and parent_names["src/private/secret.lua"] == true)

    local no_parent_zip = root .. "/filtered-no-parent.zip"
    local no_parent, no_parent_err = babet.archive.create(
        filter_source, no_parent_zip, {
            include = { "src/private/secret.lua" },
            include_directories = false,
        })
    ok_val("include filters respect include_directories=false",
        no_parent, no_parent_err,
        function(value) return value.files == 1 and value.directories == 0 end)
    local no_parent_list = babet.archive.list(no_parent_zip)
    ok("filtered creation can rely on implicit extraction parents",
        no_parent_list and no_parent_list.count == 1
        and no_parent_list.entries[1].name == "src/private/secret.lua")

    local empty_dir_zip = root .. "/filtered-empty-dir.zip"
    local empty_dir, empty_dir_err = babet.archive.create(
        filter_source, empty_dir_zip, { include = { "src/empty/" } })
    ok_val("a directory pattern can select an empty directory",
        empty_dir, empty_dir_err,
        function(value) return value.files == 0 and value.directories == 2 end)
    local empty_dir_names, empty_dir_info = archive_name_set(empty_dir_zip)
    ok("selected empty directories retain their parent path",
        empty_dir_names and empty_dir_info.count == 2
        and empty_dir_names["src/"] == true
        and empty_dir_names["src/empty/"] == true)

    local excluded_zip = root .. "/filtered-excluded.zip"
    local excluded, excluded_err = babet.archive.create(
        filter_source, excluded_zip, {
            include = { "**" },
            exclude = { "src/private/**", "cache/**", "*.log" },
        })
    ok_val("exclude patterns override include patterns",
        excluded, excluded_err)
    local excluded_names = archive_name_set(excluded_zip)
    ok("excluded directories are pruned and excluded files are absent",
        excluded_names
        and excluded_names["top.txt"] == true
        and excluded_names["top.log"] ~= true
        and excluded_names["src/private/"] ~= true
        and excluded_names["src/private/secret.lua"] ~= true
        and excluded_names["cache/"] ~= true
        and excluded_names["cache/data.bin"] ~= true)

    local exclude_only_zip = root .. "/filtered-exclude-only.zip"
    local exclude_only, exclude_only_err = babet.archive.create(
        filter_source, exclude_only_zip, {
            exclude = { "**/*.tmp", "cache/**" },
        })
    ok_val("exclude filters work without an include list",
        exclude_only, exclude_only_err)
    local exclude_only_names = archive_name_set(exclude_only_zip)
    ok("exclude-only creation otherwise preserves historical selection",
        exclude_only_names
        and exclude_only_names["top.txt"] == true
        and exclude_only_names["src/private/secret.lua"] == true
        and exclude_only_names["docs/draft.tmp"] ~= true
        and exclude_only_names["cache/data.bin"] ~= true)

    local top_only_zip = root .. "/filtered-top-only.zip"
    local top_only, top_only_err = babet.archive.create(
        filter_source, top_only_zip, { include = { "*.txt" } })
    ok_val("single-star include remains component-local",
        top_only, top_only_err,
        function(value) return value.files == 1 and value.directories == 0 end)
    local top_only_list = babet.archive.list(top_only_zip)
    ok("component-local star does not cross directory separators",
        top_only_list and top_only_list.count == 1
        and top_only_list.entries[1].name == "top.txt")

    local escaped_zip = root .. "/filtered-escaped.zip"
    local escaped, escaped_err = babet.archive.create(
        filter_source, escaped_zip, { include = { "literal\\*.dat" } })
    ok_val("glob escaping selects literal wildcard bytes",
        escaped, escaped_err)
    local escaped_list = babet.archive.list(escaped_zip)
    ok("escaped star is stored as a literal filename",
        escaped_list and escaped_list.count == 1
        and escaped_list.entries[1].name == "literal*.dat")

    local case_zip = root .. "/filtered-case.zip"
    local case_result, case_err = babet.archive.create(
        filter_source, case_zip, { include = { "TOP.TXT" } })
    ok_val("archive include globs are case-sensitive",
        case_result, case_err,
        function(value) return value.files == 0 and value.directories == 0 end)
    local case_list = babet.archive.list(case_zip)
    ok("a filter with no matches creates a valid empty archive",
        case_list and case_list.count == 0)

    local empty_include_zip = root .. "/filtered-empty-include.zip"
    local empty_include, empty_include_err = babet.archive.create(
        filter_source, empty_include_zip, { include = {}, exclude = {} })
    ok_val("empty include/exclude arrays are accepted as no-op filters",
        empty_include, empty_include_err,
        function(value)
            return value.files == 9 and value.directories == 5
                and value.include_patterns == 0
                and value.exclude_patterns == 0
        end)

    local ignored = filter_source .. "/ignored"
    assert(babet.mkdir(ignored))
    assert(babet.exec("ln", { "-s", "../top.txt", ignored .. "/link" }).code == 0)
    assert(babet.exec("mkfifo", { ignored .. "/pipe" }).code == 0)
    local pruned_zip = root .. "/filtered-pruned.zip"
    local pruned, pruned_err = babet.archive.create(
        filter_source, pruned_zip, { exclude = { "ignored/**" } })
    ok_val("an excluded directory is pruned before unsafe descendants are opened",
        pruned, pruned_err)
    local pruned_names = archive_name_set(pruned_zip)
    ok("pruned directory entries and descendants are absent",
        pruned_names and pruned_names["ignored/"] ~= true
        and pruned_names["ignored/link"] ~= true
        and pruned_names["ignored/pipe"] ~= true)
    babet.exec("rm", { "-rf", ignored })

    local optional_fifo = filter_source .. "/not-selected.fifo"
    assert(babet.exec("mkfifo", { optional_fifo }).code == 0)
    local skipped_special, skipped_special_err = babet.archive.create(
        filter_source, root .. "/filtered-skipped-special.zip", {
            include = { "top.txt" },
        })
    ok_val("unselected special filesystem objects are ignored",
        skipped_special, skipped_special_err)
    local selected_special, selected_special_err = babet.archive.create(
        filter_source, root .. "/filtered-selected-special.zip", {
            include = { "not-selected.fifo" },
        })
    ok_fail("selected special filesystem objects remain rejected",
        selected_special, selected_special_err)
    babet.exec("rm", { "-f", optional_fifo })

    local invalid_filtered_name = filter_source .. "/ignored-\255.bin"
    assert(write_bytes(invalid_filtered_name, "invalid"))
    local ignored_invalid, ignored_invalid_err = babet.archive.create(
        filter_source, root .. "/filtered-invalid-ignored.zip", {
            include = { "top.txt" },
        })
    ok_val("unselected invalid UTF-8 names do not enter the archive plan",
        ignored_invalid, ignored_invalid_err)
    babet.remove(invalid_filtered_name)

    local explicit_filtered_zip = root .. "/explicit-filtered.zip"
    local explicit_filtered, explicit_filtered_err = babet.archive.create(
        explicit_sources, explicit_filtered_zip, {
            include = { "report.txt", "list-b/nested/**" },
        })
    ok_val("include filters use final archive names for explicit sources",
        explicit_filtered, explicit_filtered_err,
        function(value)
            return value.sources == 2 and value.files == 2
                and value.directories == 2
        end)
    local explicit_filtered_names, explicit_filtered_info =
        archive_name_set(explicit_filtered_zip)
    ok("explicit-source filters keep required selected roots",
        explicit_filtered_names and explicit_filtered_info.count == 4
        and explicit_filtered_names["report.txt"] == true
        and explicit_filtered_names["list-b/"] == true
        and explicit_filtered_names["list-b/nested/"] == true
        and explicit_filtered_names["list-b/nested/data.bin"] == true
        and explicit_filtered_names["list-b/root.txt"] ~= true)

    local explicit_excluded, explicit_excluded_err = babet.archive.create(
        explicit_sources, root .. "/explicit-filter-excluded.zip", {
            include = { "**" },
            exclude = { "report.txt" },
        })
    ok_val("exclude can remove a complete explicit file source",
        explicit_excluded, explicit_excluded_err,
        function(value) return value.sources == 2 and value.files == 2 end)

    local filtered_tar_a = root .. "/filtered-a.tar"
    local filtered_tar_b = root .. "/filtered-b.tar"
    local filtered_a, filtered_a_err = babet.archive.create(
        filter_source, filtered_tar_a, {
            include = { "docs/**", "src/*.lua" },
            exclude = { "docs/*.tmp" },
        })
    local filtered_b, filtered_b_err = babet.archive.create(
        filter_source, filtered_tar_b, {
            include = { "src/*.lua", "docs/**" },
            exclude = { "docs/*.tmp" },
        })
    ok_val("safe-glob filters work with TAR creation",
        filtered_a, filtered_a_err,
        function(value) return value.format == "tar" and value.files == 2 end)
    ok_val("filtered TAR comparison fixture is created",
        filtered_b, filtered_b_err)
    ok("filter-list order does not affect deterministic archive bytes",
        read_bytes(filtered_tar_a) == read_bytes(filtered_tar_b))

    local filter_worker_code = [[
local result, err = babet.archive.create(
    worker.args.source, worker.args.destination, {
        include = { "src/*.lua" },
        exclude = { "src/private/**" },
    })
if not result then error(err) end
return { result.files, result.directories, result.include_patterns,
         result.exclude_patterns }
]]
    local filter_worker = babet.workers.spawn(filter_worker_code, {
        source = filter_source,
        destination = root .. "/filtered-worker.zip",
    })
    ok("archive filters start safely in a worker", filter_worker ~= nil)
    local filter_worker_ok, filter_worker_result = false, nil
    if filter_worker then
        filter_worker_ok, filter_worker_result = filter_worker:join()
    end
    ok("archive filters succeed in worker Lua states",
        filter_worker_ok == true and type(filter_worker_result) == "table"
        and filter_worker_result[1] == 1 and filter_worker_result[2] == 1
        and filter_worker_result[3] == 1 and filter_worker_result[4] == 1)

    local bad_include_type, bad_include_type_err = babet.archive.create(
        filter_source, root .. "/bad-filter-type.zip", { include = "*.txt" })
    ok_fail("archive.create include must be a dense array",
        bad_include_type, bad_include_type_err)
    local bad_exclude_type, bad_exclude_type_err = babet.archive.create(
        filter_source, root .. "/bad-exclude-type.zip", { exclude = false })
    ok_fail("archive.create exclude must be a dense array",
        bad_exclude_type, bad_exclude_type_err)
    local sparse_filter, sparse_filter_err = babet.archive.create(
        filter_source, root .. "/bad-filter-sparse.zip", {
            include = { [1] = "*.txt", [3] = "*.lua" },
        })
    ok_fail("archive.create filter arrays must not contain holes",
        sparse_filter, sparse_filter_err)
    local keyed_filter, keyed_filter_err = babet.archive.create(
        filter_source, root .. "/bad-filter-key.zip", {
            include = { "*.txt", extra = "*.lua" },
        })
    ok_fail("archive.create filter arrays reject non-array keys",
        keyed_filter, keyed_filter_err)
    local typed_filter, typed_filter_err = babet.archive.create(
        filter_source, root .. "/bad-filter-value.zip", {
            include = { "*.txt", 42 },
        })
    ok_fail("archive.create filters require strict string values",
        typed_filter, typed_filter_err)
    local empty_filter, empty_filter_err = babet.archive.create(
        filter_source, root .. "/bad-filter-empty.zip", { include = { "" } })
    ok_fail("archive.create rejects empty glob patterns",
        empty_filter, empty_filter_err)
    local nul_filter, nul_filter_err = babet.archive.create(
        filter_source, root .. "/bad-filter-nul.zip", {
            exclude = { "bad\0pattern" },
        })
    ok_fail("archive.create rejects NUL bytes in glob patterns",
        nul_filter, nul_filter_err)
    local escape_filter, escape_filter_err = babet.archive.create(
        filter_source, root .. "/bad-filter-escape.zip", {
            include = { "trailing\\" },
        })
    ok_fail("archive.create rejects a trailing glob escape",
        escape_filter, escape_filter_err)
    local long_filter, long_filter_err = babet.archive.create(
        filter_source, root .. "/bad-filter-long.zip", {
            include = { string.rep("x", 4097) },
        })
    ok_fail("archive.create enforces the 4096-byte per-pattern limit",
        long_filter, long_filter_err)

    local max_pattern, max_pattern_err = babet.archive.create(
        filter_source, root .. "/filter-4096.zip", {
            include = { string.rep("x", 4096) },
        })
    ok_val("archive.create accepts a 4096-byte glob pattern",
        max_pattern, max_pattern_err,
        function(value) return value.files == 0 and value.directories == 0 end)

    local too_many_patterns = {}
    for i = 1, 257 do too_many_patterns[i] = "never-" .. i end
    local many_filter, many_filter_err = babet.archive.create(
        filter_source, root .. "/bad-filter-count.zip", {
            include = too_many_patterns,
        })
    ok_fail("archive.create enforces the combined 256-pattern limit",
        many_filter, many_filter_err)

    local too_many_pattern_bytes = {}
    for i = 1, 65 do
        too_many_pattern_bytes[i] = string.rep(string.char(64 + (i % 26)), 4096)
    end
    local bytes_filter, bytes_filter_err = babet.archive.create(
        filter_source, root .. "/bad-filter-bytes.zip", {
            include = too_many_pattern_bytes,
        })
    ok_fail("archive.create enforces the combined 256 KiB pattern limit",
        bytes_filter, bytes_filter_err)

    local work_source = root .. "/filter-work-source"
    assert(babet.mkdir(work_source))
    assert(write_bytes(work_source .. "/" .. string.rep("a", 250), "a"))
    assert(write_bytes(work_source .. "/" .. string.rep("b", 250), "b"))
    local expensive_patterns = {}
    for i = 1, 64 do expensive_patterns[i] = string.rep("z", 4096) end
    local work_filter, work_filter_err = babet.archive.create(
        work_source, root .. "/bad-filter-work.zip", {
            include = expensive_patterns,
        })
    ok_fail("archive.create bounds cumulative glob matching work",
        work_filter, work_filter_err)
    ok("glob work-limit failure leaves no archive output",
        babet.fileExists(root .. "/bad-filter-work.zip") == false)
    end)()

    end
end
