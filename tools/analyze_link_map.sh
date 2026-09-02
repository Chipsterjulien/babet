#!/bin/bash
# Attribute linked input-section bytes from a GNU ld map to coarse Babet areas.
# This is a maintainer diagnostic, NOT a removable-size calculator.
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 <linker-map> <stripped-binary> [report]" >&2
    exit 1
fi
MAP_FILE="$1"
BINARY="$2"
REPORT="${3:-}"

for f in "${MAP_FILE}" "${BINARY}"; do
    if [[ ! -f "${f}" ]]; then
        echo "ERREUR: fichier introuvable : ${f}" >&2
        exit 1
    fi
done
if ! command -v awk >/dev/null 2>&1; then
    echo "ERREUR: awk est requis pour l'analyse de taille." >&2
    exit 1
fi
if ! command -v stat >/dev/null 2>&1; then
    echo "ERREUR: stat est requis pour l'analyse de taille." >&2
    exit 1
fi

BINARY_SIZE="$(stat -Lc '%s' -- "${BINARY}")"
TMP="$(mktemp "${TMPDIR:-/tmp}/babet-size-attribution.XXXXXX")"
trap 'rm -f -- "${TMP}"' EXIT

awk -v binary_size="${BINARY_SIZE}" '
function hex2dec(h,    i,c,n,digits) {
    digits="0123456789abcdef"
    sub(/^0x/, "", h)
    h=tolower(h)
    n=0
    for (i=1; i<=length(h); ++i) {
        c=substr(h,i,1)
        n=n*16 + index(digits,c)-1
    }
    return n
}
function cat_for(archive, member, line,    m,a) {
    m=tolower(member); a=tolower(archive)
    if (a == "libbabet.a") {
        if (m == "gui.cpp.o" || m == "gui_gtk_loader.cpp.o") return "GUI bridge (Babet code)"
        if (m == "curses.cpp.o") return "ncursesw (Babet binding)"
        if (m == "sqlite.cpp.o" || m == "sqlite_backup_file.cpp.o" || m == "sqlite3.c.o") return "SQLite"
        if (m == "archive.cpp.o" || m == "compression.cpp.o" || m == "archive_backend.cpp.o" || m == "archive_tar.cpp.o" || m == "compression_stream.cpp.o") return "Archive/compression (Babet code)"
        if (m == "http.cpp.o" || m == "http_download_file.cpp.o" || m == "socket.cpp.o" || m == "websocket.cpp.o") return "Network/TLS/WebSocket (Babet code)"
        if (m == "find.cpp.o") return "find/RE2 (Babet code)"
        if (m == "native_plugin.cpp.o") return "Native plugins"
        if (m == "babet_c_api.cpp.o" || m == "host_call_api.cpp.o") return "Embedding/host API"
        if (m == "workers.cpp.o") return "Workers"
        if (m == "process.cpp.o" || m == "process_common.cpp.o" || m == "process_launch_internal.cpp.o" || m == "process_terminal_internal.cpp.o" || m == "pipeline.cpp.o" || m == "exec.cpp.o") return "Process/pipeline"
        if (m == "create_executable.cpp.o" || m == "embedded_searcher.cpp.o" || m == "zip_utils.cpp.o" || m == "miniz.c.o") return "Packaging/--create-exe"
        if (m == "bundled_modules.cpp.o") return "Bundled Lua modules"
        if (m == "json.cpp.o" || m == "toml.cpp.o") return "Data formats"
        if (m == "md5.cpp.o" || m == "sha1.cpp.o" || m == "sha256.cpp.o" || m == "sha384.cpp.o" || m == "sha512.cpp.o" || m == "sha3_256.cpp.o" || m == "sha3_384.cpp.o" || m == "sha3_512.cpp.o" || m == "blake2b.cpp.o" || m == "blake2s.cpp.o" || m == "crc32.cpp.o" || m == "checksum_utils.cpp.o" || m == "base64.cpp.o") return "Hashing/base64 (Babet code)"
        return "Other Babet runtime"
    }
    if (a ~ /^liblua/) return "Lua runtime"
    if (a ~ /^libncurses/ || a ~ /^libtinfo/) return "ncursesw (static dependency)"
    if (a == "libarchive.a" || a == "libz.a" || a == "liblzma.a" || a == "libbz2.a" || a == "libzstd.a") return "Archive/compression dependencies"
    if (a == "libssl.a" || a == "libcrypto.a") return "OpenSSL crypto/TLS (shared)"
    if (a == "libre2.a" || a ~ /^libabsl_.*[.]a$/) return "RE2/Abseil dependencies"
    if (a == "libstdc++.a" || a == "libsupc++.a" || a == "libgcc.a" || a == "libgcc_eh.a") return "C++/GCC static runtime"
    if (a != "") return "Other static dependency"
    if (index(line, "main.cpp.o")) return "CLI main"
    return ""
}
function add_sorted(src, prefix,    k,n,i,j,tmp,names) {
    n=0
    for (k in src) { n++; names[n]=k }
    for (i=1; i<=n; ++i) {
        for (j=i+1; j<=n; ++j) {
            if (src[names[j]] > src[names[i]] || (src[names[j]] == src[names[i]] && names[j] < names[i])) {
                tmp=names[i]; names[i]=names[j]; names[j]=tmp
            }
        }
    }
    for (i=1; i<=n; ++i) order[prefix,i]=names[i]
    count[prefix]=n
}
function pct(n,d) { return d ? (100.0*n/d) : 0 }
BEGIN { section=""; attributed=0 }
{
    # Do not depend on GNU ld heading text: binutils map headings may be
    # translated by the process locale.  Recognised section/input records are
    # sufficient to identify the useful part of the map.
    line=$0

    if ($1 ~ /^\.[A-Za-z0-9_.-]+$/ && $2 ~ /^0x[0-9A-Fa-f]+$/) section=$1
    if (section ~ /^\.bss/ || section ~ /^\.tbss/ || section ~ /^\.sbss/ || section ~ /^\.debug/ || section == ".comment" || section == ".symtab" || section == ".strtab" || section == ".shstrtab") next

    h1=""; h2=""
    for (i=1; i<=NF; ++i) {
        if ($i ~ /^0x[0-9A-Fa-f]+$/) {
            if (h1 == "") h1=$i
            else { h2=$i; break }
        }
    }
    if (h2 == "") next
    bytes=hex2dec(h2)
    if (bytes <= 0) next

    archive=""; member=""; token=""
    if (match(line, /libbabet[.]a\([^)]*\)/)) {
        token=substr(line,RSTART,RLENGTH); archive="libbabet.a"
        member=token; sub(/^libbabet[.]a\(/,"",member); sub(/\)$/,"",member)
    } else if (match(line, /[A-Za-z0-9_.+~-]+[.]a\([^)]*\)/)) {
        token=substr(line,RSTART,RLENGTH)
        archive=token; sub(/\(.*/,"",archive)
        member=token; sub(/^[^(]*\(/,"",member); sub(/\)$/,"",member)
    }

    category=cat_for(archive,member,line)
    if (category == "") next
    cat[category]+=bytes; attributed+=bytes
    if (archive != "") input=archive "(" member ")"; else input="main.cpp.o"
    inp[input]+=bytes
}
END {
    if (attributed <= 0) {
        print "ERROR\tno attributable linked bytes found in GNU ld map"
        print "ERROR\tthe parser is locale-independent; inspect the map input format"
        exit 3
    }

    print "Babet binary size attribution audit"
    print "==================================="
    print ""
    printf "On-disk stripped binary size: %.0f bytes\n", binary_size
    printf "Attributed input-section bytes: %.0f bytes\n", attributed
    print ""
    print "IMPORTANT: these figures are linker-map attribution, NOT removable-size deltas."
    print "Shared dependencies, alignment, linker-generated relocations, COMDAT folding"
    print "and cross-feature references make categories non-additive. Use this report only"
    print "to choose candidates for later one-feature-at-a-time differential builds."
    print ""
    print "Categories"
    print "----------"
    add_sorted(cat,"c")
    for (i=1; i<=count["c"]; ++i) {
        k=order["c",i]
        printf "%-42s %10.0f bytes  %6.2f%% attributed  %6.2f%% file\n", k, cat[k], pct(cat[k],attributed), pct(cat[k],binary_size)
    }
    print ""
    print "Top linked inputs"
    print "-----------------"
    add_sorted(inp,"i")
    limit=count["i"] < 40 ? count["i"] : 40
    for (i=1; i<=limit; ++i) {
        k=order["i",i]
        printf "%-58s %10.0f bytes\n", k, inp[k]
    }
}
' "${MAP_FILE}" > "${TMP}" || {
    status=$?
    if [[ -s "${TMP}" ]]; then
        cat "${TMP}" >&2
    else
        echo "ERREUR: awk a échoué pendant l'analyse de la map GNU ld (code ${status})." >&2
    fi
    exit "${status}"
}

if grep -q '^ERROR[[:space:]]' "${TMP}"; then
    cat "${TMP}" >&2
    exit 1
fi

if [[ -n "${REPORT}" ]]; then
    mkdir -p "$(dirname -- "${REPORT}")"
    cp -- "${TMP}" "${REPORT}"
fi
cat "${TMP}"
