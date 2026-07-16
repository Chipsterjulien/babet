#include "archive_backend.hpp"

#include <archive.h>
#include <zlib.h>
#include <lzma.h>
#include <bzlib.h>
#include <zstd.h>

namespace babet::archive_backend
{
RuntimeInfo inspect_runtime() noexcept
{
    return RuntimeInfo{
        .header_version = ARCHIVE_VERSION_NUMBER,
        .runtime_version = archive_version_number(),
        .runtime_version_string = archive_version_string(),
        .zlib_header_version = ZLIB_VERSION,
        .zlib_runtime_version = zlibVersion(),
        .lzma_header_version = LZMA_VERSION_STRING,
        .lzma_runtime_version = lzma_version_string(),
        .bzip2_expected_version = BABET_BZIP2_EXPECTED_VERSION,
        .bzip2_runtime_version = BZ2_bzlibVersion(),
        .zstd_header_version = ZSTD_VERSION_STRING,
        .zstd_runtime_version = ZSTD_versionString(),
    };
}
}
