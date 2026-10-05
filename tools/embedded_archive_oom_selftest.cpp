#include "project_core/zip_utils.hpp"
#include <miniz.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <new>
#include <unistd.h>

namespace
{
bool count_allocations = false;
bool fail_allocations = false;
std::size_t allocation_count = 0;
std::size_t allocation_budget = 0;
}
void *operator new(std::size_t size)
{
    if (count_allocations)
    {
        ++allocation_count;
        if (fail_allocations && allocation_budget == 0) throw std::bad_alloc();
        if (fail_allocations) --allocation_budget;
    }
    void *p = std::malloc(size ? size : 1);
    if (!p) throw std::bad_alloc();
    return p;
}
void operator delete(void *p) noexcept { std::free(p); }
void *operator new[](std::size_t size) { return ::operator new(size); }
void operator delete[](void *p) noexcept { ::operator delete(p); }
void operator delete(void *p, std::size_t) noexcept { ::operator delete(p); }
void operator delete[](void *p, std::size_t) noexcept { ::operator delete(p); }

namespace
{
std::size_t count_fds()
{
    DIR *dir = opendir("/proc/self/fd");
    if (!dir) std::abort();
    std::size_t count = 0;
    while (dirent *entry = readdir(dir))
        if (std::strcmp(entry->d_name, ".") && std::strcmp(entry->d_name, "..")) ++count;
    closedir(dir);
    return count;
}

bool make_archive(const char *file, const std::string &name, std::size_t size, bool corrupt)
{
    mz_zip_archive zip{};
    std::vector<char> data(size, 'x');
    if (!mz_zip_writer_init_file(&zip, file, 0)) return false;
    const bool added = mz_zip_writer_add_mem(&zip, name.c_str(), data.data(), data.size(),
                                             corrupt ? 0 : MZ_BEST_SPEED);
    const bool finished = added && mz_zip_writer_finalize_archive(&zip);
    mz_zip_writer_end(&zip);
    if (!finished) return false;
    if (corrupt)
    {
        // Corrupt only the payload, retaining valid directory metadata and
        // the original CRC. Reading must reach the extraction-error branch.
        FILE *stream = std::fopen(file, "r+b");
        if (!stream) return false;
        const bool wrote = std::fseek(stream, 30 + static_cast<long>(name.size()), SEEK_SET) == 0 &&
                           std::fputc('y', stream) != EOF;
        const bool closed = std::fclose(stream) == 0;
        if (!wrote || !closed) return false;
    }
    return true;
}

bool one_read(const std::string &file, const std::string &name, const char *error_needle,
              bool inject, std::size_t budget, std::size_t &calls)
{
    const std::size_t before = count_fds();
    std::string error;
    bool threw = false, content_ok = false;
    allocation_count = 0;
    allocation_budget = budget;
    fail_allocations = inject;
    count_allocations = true;
    try
    {
        auto data = readEmbeddedFile(file, name, &error);
        count_allocations = fail_allocations = false;
        content_ok = error_needle ? !data && error.find(error_needle) != std::string::npos
                                 : data && data->size() == 8192 && error.empty();
    }
    catch (const std::bad_alloc &)
    {
        count_allocations = fail_allocations = false;
        threw = true;
    }
    calls = allocation_count;
    const std::size_t after = count_fds();
    const bool ok = before == after && (inject ? threw : content_ok);
    if (!ok)
        std::fprintf(stderr, "[FAIL] embedded archive: inject=%d budget=%zu fds=%zu->%zu "
                     "threw=%d content_ok=%d\n", inject, budget, before, after, threw, content_ok);
    return ok;
}
}

int main()
{
    char pattern[] = "/tmp/babet-archive-oom.XXXXXX";
    const int descriptor = mkstemp(pattern);
    if (descriptor < 0) return 2;
    close(descriptor);
    const std::string file = pattern;
    const std::string name = "module_with_a_long_name_for_diagnostic_allocation_failure.lua";
    const char *errors[] = {nullptr, "exceeds maximum", "cannot extract"};
    const char *names[] = {"valid entry", "oversized entry", "corrupt entry"};
    std::size_t runs = 0;
    bool ok = true;
    for (int scenario = 0; scenario < 3 && ok; ++scenario)
    {
        if (!make_archive(file.c_str(), name,
                          scenario == 1 ? MAX_EMBEDDED_FILE_SIZE + 1 : 8192, scenario == 2))
        { ok = false; break; }
        std::size_t calls = 0, unused = 0;
        ok = one_read(file, name, errors[scenario], false, 0, calls);
        ++runs;
        if (calls == 0) ok = false;
        for (std::size_t budget = 0; budget < calls && ok; ++budget)
        {
            ok = one_read(file, name, errors[scenario], true, budget, unused);
            ++runs;
        }
        if (ok) std::printf("[PASS] embedded archive %s: %zu C++ failure points, no FD leak\n",
                            names[scenario], calls);
    }
    unlink(pattern);
    if (!ok) return 1;
    std::printf("embedded archive OOM: %zu runs / 0 leaked descriptors\n", runs);
    return 0;
}
