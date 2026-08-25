#!/bin/bash
# Helpers shared by build_local.sh and the lightweight dependency bootstrap
# regression tests. This file defines functions only and is safe to source.

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
