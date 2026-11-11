#!/bin/bash
# Helpers shared by build_local.sh and the lightweight dependency bootstrap
# regression tests. This file defines functions only and is safe to source.

# Call only when a dependency needs rebuilding, AFTER verify_sha256. Reuse
# complete installations, but rebuild from a fresh source tree: an existing
# directory or build entry point alone cannot prove a complete extraction.
# Arguments: final source directory, verified archive, archive root, inputs.
babet_refresh_dependency_source() {
    local source_dir="$1"
    local archive_path="$2"
    local archive_root_name="$3"
    shift 3
    local root_dir extract_dir extracted_source file
    root_dir="$(dirname -- "${source_dir}")"
    mkdir -p "${root_dir}" || return 1
    extract_dir="$(mktemp -d "${root_dir}/.extract-${archive_root_name}.XXXXXX")" || return 1
    extracted_source="${extract_dir}/${archive_root_name}"

    case "${archive_path}" in
        *.zip)
            if ! unzip -q "${archive_path}" -d "${extract_dir}"; then
                rm -rf -- "${extract_dir}"
                return 1
            fi
            ;;
        *)
            if ! tar -xf "${archive_path}" -C "${extract_dir}"; then
                rm -rf -- "${extract_dir}"
                return 1
            fi
            ;;
    esac

    if [ ! -d "${extracted_source}" ]; then
        rm -rf -- "${extract_dir}"
        return 1
    fi
    for file in "$@"; do
        if [ ! -f "${extracted_source}/${file}" ]; then
            rm -rf -- "${extract_dir}"
            return 1
        fi
    done
    if ! rm -rf -- "${source_dir}" || \
       ! mv -- "${extracted_source}" "${source_dir}"; then
        rm -rf -- "${extract_dir}"
        return 1
    fi
    rm -rf -- "${extract_dir}"
}

babet_lua_install_complete() {
    local source_dir="$1"
    local file
    for file in liblua.a lua.h lauxlib.h lualib.h luaconf.h; do
        [ -f "${source_dir}/src/${file}" ] || return 1
    done
    return 0
}

# The mere presence of a source directory (or a leftover libbz2.a) does not
# imply a complete extraction. Check every input needed by `make libbz2.a`,
# including words0, which the upstream Makefile reads before compiling.
babet_bzip2_source_complete() {
    local source_dir="$1"
    local file
    for file in Makefile bzlib.h bzlib_private.h words0 \
            blocksort.c huffman.c crctable.c randtable.c \
            compress.c decompress.c bzlib.c; do
        [ -f "${source_dir}/${file}" ] || return 1
    done
    return 0
}

# The caller verifies the archive's pinned SHA256 before calling this helper.
# Extract and validate separately so a failed extraction leaves the old source
# tree untouched. A successful repair discards stale objects and archives.
babet_prepare_bzip2_source() {
    local source_dir="$1"
    local root_dir="$2"
    local archive_path="$3"
    local archive_root_name="$4"

    if babet_bzip2_source_complete "${source_dir}"; then
        return 0
    fi

    local extract_dir
    mkdir -p "${root_dir}" || return 1
    extract_dir="$(mktemp -d "${root_dir}/.extract-${archive_root_name}.XXXXXX")" || return 1
    local extracted_source="${extract_dir}/${archive_root_name}"

    if ! tar -xzf "${archive_path}" -C "${extract_dir}" || \
       ! babet_bzip2_source_complete "${extracted_source}"; then
        rm -rf -- "${extract_dir}"
        return 1
    fi

    if ! rm -rf -- "${source_dir}" || \
       ! mv -- "${extracted_source}" "${source_dir}"; then
        rm -rf -- "${extract_dir}"
        return 1
    fi
    rm -rf -- "${extract_dir}"
}

babet_zstd_install_complete() {
    local library_path="$1"
    local include_dir="$2"

    [ -f "${library_path}" ] && \
        [ -f "${include_dir}/zstd.h" ] && \
        [ -f "${include_dir}/zstd_errors.h" ]
}

babet_zstd_source_complete() {
    local source_dir="$1"
    [ -f "${source_dir}/build/cmake/CMakeLists.txt" ]
}

babet_prepare_zstd_source() {
    local source_dir="$1"
    local root_dir="$2"
    local archive_path="$3"
    local archive_root_name="$4"

    if babet_zstd_source_complete "${source_dir}"; then
        return 0
    fi

    local extract_dir="${root_dir}/.extract-${archive_root_name}-$$"
    rm -rf "${extract_dir}"
    mkdir -p "${extract_dir}"

    if ! tar -xzf "${archive_path}" -C "${extract_dir}"; then
        rm -rf "${extract_dir}"
        return 1
    fi

    local extracted_source="${extract_dir}/${archive_root_name}"
    if ! babet_zstd_source_complete "${extracted_source}"; then
        rm -rf "${extract_dir}"
        return 1
    fi

    rm -rf "${source_dir}"
    if ! mv "${extracted_source}" "${source_dir}"; then
        rm -rf "${extract_dir}"
        return 1
    fi

    rm -rf "${extract_dir}"
    return 0
}


babet_ncurses_source_complete() {
    local source_dir="$1"
    [ -f "${source_dir}/configure" ] && \
        [ -f "${source_dir}/install-sh" ] && \
        [ -f "${source_dir}/config.guess" ] && \
        [ -f "${source_dir}/config.sub" ] && \
        [ -f "${source_dir}/misc/terminfo.src" ] && \
        [ -f "${source_dir}/COPYING" ]
}

babet_prepare_ncurses_source() {
    local source_dir="$1"
    local root_dir="$2"
    local archive_path="$3"
    local archive_root_name="$4"

    if babet_ncurses_source_complete "${source_dir}"; then
        return 0
    fi

    local extract_dir="${root_dir}/.extract-${archive_root_name}-$$"
    rm -rf "${extract_dir}"
    mkdir -p "${extract_dir}"

    if ! tar -xzf "${archive_path}" -C "${extract_dir}"; then
        rm -rf "${extract_dir}"
        return 1
    fi

    local extracted_source="${extract_dir}/${archive_root_name}"
    if ! babet_ncurses_source_complete "${extracted_source}"; then
        rm -rf "${extract_dir}"
        return 1
    fi

    rm -rf "${source_dir}"
    if ! mv "${extracted_source}" "${source_dir}"; then
        rm -rf "${extract_dir}"
        return 1
    fi

    rm -rf "${extract_dir}"
    return 0
}

# Create the ncurses fallback-generation workspace outside the project tree.
# MKfallback.sh historically expands its temporary terminfo directory without
# quoting it, so the current working directory must itself contain no spaces.
# The source and bootstrap tools may live below a path with spaces: only the
# symlink names exposed inside this workspace are passed to ncurses.
babet_prepare_ncurses_final_workspace() {
    local source_dir="$1"
    local tic_path="$2"
    local infocmp_path="$3"
    local workspace

    workspace="$(mktemp -d /tmp/babet-ncurses-final.XXXXXX)" || return 1
    case "${workspace}" in
        *' '*)
            rm -rf "${workspace}"
            return 1
            ;;
    esac

    mkdir -p "${workspace}/build" "${workspace}/tools" || {
        rm -rf "${workspace}"
        return 1
    }
    ln -s "${source_dir}" "${workspace}/source" || {
        rm -rf "${workspace}"
        return 1
    }
    ln -s "${tic_path}" "${workspace}/tools/tic" || {
        rm -rf "${workspace}"
        return 1
    }
    ln -s "${infocmp_path}" "${workspace}/tools/infocmp" || {
        rm -rf "${workspace}"
        return 1
    }

    printf '%s\n' "${workspace}"
}
