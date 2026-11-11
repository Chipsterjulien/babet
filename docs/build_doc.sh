#!/usr/bin/env bash
# build_doc.sh — generate the Babet manual PDFs from per-language
# Markdown sources, auto-detecting which languages are present.
#
# Discovery is driven by docs/manual_order_<lang>.txt files :
# every such file is taken as evidence that docs/<lang>/ exists and
# wants a PDF built. Add a new language by creating
# docs/<newlang>/... + docs/manual_order_<newlang>.txt — this script
# will pick it up automatically.
#
# Usage :
#   ./build_doc.sh                  # build every detected language
#   ./build_doc.sh en               # build only EN
#   ./build_doc.sh en fr            # build EN and FR explicitly
#   ./build_doc.sh --clean          # remove all generated PDFs
#   ./build_doc.sh --list           # list detected languages, build nothing
#   ./build_doc.sh -h | --help      # show help
#
# Languages are built in parallel, one job per language. Each job's
# output is captured and printed as one block, in the order of the
# language list, followed by a per-language report and the totals.
#
# Requirements : pandoc + a LaTeX engine (xelatex, lualatex, or pdflatex).
# xelatex is recommended for proper UTF-8 / accent handling.
#
# Exit codes :
#   0  — at least one PDF was built successfully (or --clean/--list ran)
#   1  — usage error (unknown flag, etc.)
#   2  — prerequisite missing (pandoc or LaTeX engine not found)
#   3  — at least one build failed

set -u

# ---- Resolve script location, regardless of where it's called from --
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- Defaults --------------------------------------------------------
PDF_ENGINE_DEFAULT="xelatex"
PDF_ENGINE="${PDF_ENGINE:-$PDF_ENGINE_DEFAULT}"

# ---- Helpers ---------------------------------------------------------
die() {
    echo "build_doc: $1" >&2
    exit "${2:-1}"
}

show_help() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Look up a human-friendly title for a language code. Falls back to a
# generic title for codes we don't know. Add cases as new languages
# are added.
title_for_lang() {
    case "$1" in
        en) echo "Babet Manual" ;;
        fr) echo "Manuel Babet" ;;
        de) echo "Babet Handbuch" ;;
        es) echo "Manual Babet" ;;
        it) echo "Manuale Babet" ;;
        pt) echo "Manual do Babet" ;;
        *)  echo "Babet Manual ($1)" ;;
    esac
}

# Read the ordered list of files from manual_order_<lang>.txt,
# stripping comments and blank lines. Paths are relative to REPO_ROOT.
read_order_file() {
    local order="$1"
    grep -vE '^\s*(#|$)' "$order" || true
}

# Discover languages from the manual_order_*.txt files in SCRIPT_DIR.
# Prints each detected lang code on its own line. A language is only
# returned if its corresponding docs/<lang>/ directory exists too.
discover_languages() {
    local order lang
    for order in "$SCRIPT_DIR"/manual_order_*.txt; do
        [ -f "$order" ] || continue
        lang="$(basename "$order" .txt)"
        lang="${lang#manual_order_}"
        if [ ! -d "$SCRIPT_DIR/$lang" ]; then
            echo "build_doc: warning: $order exists but $SCRIPT_DIR/$lang/ does not, skipping '$lang'" >&2
            continue
        fi
        echo "$lang"
    done
}

# Check that all required tools are present.
check_prereqs() {
    command -v pandoc >/dev/null 2>&1 || die "pandoc not found (install: pacman -S pandoc / apt install pandoc)" 2
    command -v python3 >/dev/null 2>&1 || die "python3 not found (required by preprocess_pdf.py)" 2
    command -v "$PDF_ENGINE" >/dev/null 2>&1 || \
        die "PDF engine '$PDF_ENGINE' not found (install: pacman -S texlive-xetex / apt install texlive-xetex). Override with PDF_ENGINE=lualatex or pdflatex." 2
}

# Build a single language. Returns 0 on success, non-zero on failure.
build_one() {
    local lang="$1"
    local order="$SCRIPT_DIR/manual_order_$lang.txt"
    local out="$SCRIPT_DIR/manual-$lang.pdf"

    if [ ! -f "$order" ]; then
        echo "build_doc: no order file for '$lang' ($order), skipping" >&2
        return 1
    fi

    # Collect the files to feed pandoc, in order. Read into an array
    # so that paths with spaces would still work (though the project
    # doesn't have any).
    local files=()
    local line
    while IFS= read -r line; do
        files+=("$line")
    done < <(read_order_file "$order")

    if [ ${#files[@]} -eq 0 ]; then
        echo "build_doc: $order has no active files, skipping '$lang'" >&2
        return 1
    fi

    local title
    title="$(title_for_lang "$lang")"

    # ---- Pre-processing for PDF-friendly internal links --------------
    # Generate a transient docs/build_<lang>/ tree with the .md sources
    # rewritten for the PDF context :
    #   - language toggles stripped
    #   - {#ch-xxx} ids injected on chapter H1s
    #   - [text](other.md) links rewritten to [text](#ch-xxx)
    #   - links to other repository files rewritten to public URLs
    # The chapter list comes from the order file. A broken link, or a
    # chapter missing from the order file, fails the build.
    # The original docs/<lang>/ sources are never modified.
    local build_dir="$SCRIPT_DIR/build_$lang"
    local preprocess="$SCRIPT_DIR/preprocess_pdf.py"

    if [ ! -f "$preprocess" ] || [ ! -r "$preprocess" ]; then
        echo "build_doc: preprocess script not found or not readable: $preprocess" >&2
        return 1
    fi

    echo "Preprocessing docs/$lang/ -> docs/build_$lang/"
    python3 "$preprocess" "$SCRIPT_DIR/$lang" "$build_dir" "$order" || {
        echo "build_doc: preprocess failed for '$lang'" >&2
        return 1
    }

    # Rewrite the file list: replace docs/<lang>/ -> docs/build_<lang>/
    # so pandoc reads the preprocessed copies, not the originals.
    local prep_files=()
    for f in "${files[@]}"; do
        prep_files+=("${f/docs\/$lang\//docs/build_$lang/}")
    done

    echo "Building $out  ($lang, ${#prep_files[@]} files)"

    # pandoc reads paths relative to its CWD, so we run from REPO_ROOT
    # — the same convention used by manual_order_<lang>.txt itself.
    local rc=0
    (
        cd "$REPO_ROOT" || exit 1
        pandoc "${prep_files[@]}" \
            --toc \
            --pdf-engine="$PDF_ENGINE" \
            --metadata title="$title" \
            --metadata lang="$lang" \
            --variable=geometry:margin=2cm \
            --variable=colorlinks:true \
            --variable=linkcolor:blue \
            --variable=urlcolor:blue \
            --variable=mainfont:'DejaVu Serif' \
            --variable=sansfont:'DejaVu Sans' \
            --variable=monofont:'DejaVu Sans Mono' \
            -o "$out"
    )
    rc=$?

    # Clean up the transient build dir on success. On failure we keep
    # it so the user can inspect what pandoc saw.
    if [ "$rc" -eq 0 ]; then
        rm -rf "$build_dir"
    else
        echo "build_doc: pandoc failed; preprocessed sources kept in $build_dir for inspection" >&2
    fi

    return "$rc"
}

# ---- Argument parsing ------------------------------------------------
WANT_CLEAN=0
WANT_LIST=0
EXPLICIT_LANGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        --clean)
            WANT_CLEAN=1
            shift
            ;;
        --list)
            WANT_LIST=1
            shift
            ;;
        -*)
            die "unknown option: $1 (try --help)" 1
            ;;
        *)
            EXPLICIT_LANGS+=("$1")
            shift
            ;;
    esac
done

# ---- Modes -----------------------------------------------------------
if [ "$WANT_CLEAN" -eq 1 ]; then
    removed=0
    for pdf in "$SCRIPT_DIR"/manual-*.pdf; do
        [ -f "$pdf" ] || continue
        rm -f "$pdf"
        echo "removed: $pdf"
        removed=$((removed + 1))
    done
    echo "$removed PDF(s) removed."
    exit 0
fi

if [ "$WANT_LIST" -eq 1 ]; then
    echo "Detected languages :"
    while IFS= read -r lang; do
        [ -n "$lang" ] && echo "  $lang ($(title_for_lang "$lang"))"
    done < <(discover_languages)
    exit 0
fi

# ---- Build mode ------------------------------------------------------
check_prereqs

if [ ${#EXPLICIT_LANGS[@]} -gt 0 ]; then
    languages=("${EXPLICIT_LANGS[@]}")
else
    languages=()
    while IFS= read -r lang; do
        [ -n "$lang" ] && languages+=("$lang")
    done < <(discover_languages)
fi

if [ ${#languages[@]} -eq 0 ]; then
    die "no languages to build (looked for $SCRIPT_DIR/manual_order_*.txt)" 1
fi

# Two jobs for the same language would write the same build directory
# and the same PDF: keep the first occurrence of each language only.
unique_languages=()
for lang in "${languages[@]}"; do
    duplicate=0
    for seen in "${unique_languages[@]:+${unique_languages[@]}}"; do
        [ "$seen" = "$lang" ] && { duplicate=1; break; }
    done
    [ "$duplicate" -eq 0 ] && unique_languages+=("$lang")
done
languages=("${unique_languages[@]}")

# ---- Parallel build --------------------------------------------------
# One background job per language. Each job writes its output to its own
# log, so the blocks are never interleaved, and records its duration.
log_dir="$(mktemp -d "${TMPDIR:-/tmp}/babet-build-doc.XXXXXX")" || \
    die "cannot create a temporary directory for the build logs" 1

pids=()
cleanup() {
    rm -rf -- "$log_dir"
}
# Jobs run in their own process groups (job control below), so Ctrl-C
# reaches only this script: stop every job, pandoc and LaTeX included.
interrupted() {
    local pid
    for pid in "${pids[@]:+${pids[@]}}"; do
        kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    done
    wait 2>/dev/null
    cleanup
    echo >&2
    echo "build_doc: interrupted, builds stopped" >&2
    exit 130
}
trap cleanup EXIT
trap interrupted INT TERM

if [ ${#languages[@]} -gt 1 ]; then
    echo "Building ${#languages[@]} manuals in parallel: ${languages[*]}"
fi

set -m  # job control: each job becomes the leader of its own process group
for index in "${!languages[@]}"; do
    lang="${languages[$index]}"
    (
        started=$SECONDS
        build_one "$lang"
        rc=$?
        echo $((SECONDS - started)) > "$log_dir/$index.seconds"
        exit "$rc"
    ) > "$log_dir/$index.log" 2>&1 < /dev/null &
    pids+=("$!")
done
set +m

# Collect in list order: print each job's block once it has finished.
ok=0
fail=0
report=()
for index in "${!languages[@]}"; do
    lang="${languages[$index]}"
    rc=0
    wait "${pids[$index]}" || rc=$?
    cat "$log_dir/$index.log"
    seconds="$(cat "$log_dir/$index.seconds" 2>/dev/null || echo "?")"
    if [ "$rc" -eq 0 ]; then
        ok=$((ok + 1))
        report+=("  [OK]    $lang  manual-$lang.pdf  (${seconds} s)")
    else
        fail=$((fail + 1))
        report+=("  [FAIL]  $lang  manual-$lang.pdf  (${seconds} s)")
    fi
done

echo
echo "=========================================="
printf '%s\n' "${report[@]}"
echo "Built : $ok    Failed : $fail    Total : ${#languages[@]}"
echo "=========================================="

if [ "$fail" -gt 0 ]; then
    exit 3
fi