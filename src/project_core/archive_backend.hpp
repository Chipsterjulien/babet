#pragma once

namespace babet::archive_backend
{
/**
 * @brief Header and runtime information for the linked libarchive backend.
 *
 * The structure contains only scalar values and a pointer owned by libarchive,
 * so collecting it cannot allocate or throw. This keeps the startup probe safe
 * even before the rest of Babet has been initialised.
 */
struct RuntimeInfo
{
    int header_version;
    int runtime_version;
    const char *runtime_version_string;
    const char *zlib_header_version;
    const char *zlib_runtime_version;
    const char *lzma_header_version;
    const char *lzma_runtime_version;
    const char *bzip2_expected_version;
    const char *bzip2_runtime_version;
    const char *zstd_header_version;
    const char *zstd_runtime_version;
};

/**
 * @brief Return the compile-time and linked libarchive/zlib/liblzma/libbz2/libzstd versions.
 *
 * build_local.sh links all five libraries statically. zlib, liblzma and
 * libzstd expose compile-time and runtime versions; libbz2 exposes its runtime
 * version while the pinned expected version is injected by CMake. The gzip,
 * xz, bzip2 and zstd TAR readers rely on this exact backend.
 */
[[nodiscard]] RuntimeInfo inspect_runtime() noexcept;
}
