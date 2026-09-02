#!/bin/bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
pass(){ echo "[PASS] $1"; PASS=$((PASS+1)); }
fail(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
req_file(){ if [[ -f "$ROOT/$1" ]]; then pass "$2"; else fail "$2"; fi; }
req_grep(){ if grep -Eq "$1" "$ROOT/$2"; then pass "$3"; else fail "$3"; fi; }

req_file "SIZE_PROFILES_STUDY.md" "size/profile study contract exists"
req_file "SIZE_PROFILES_STUDY.fr.md" "French size/profile study exists"
req_file "tools/analyze_link_map.sh" "shell/awk link-map analyser exists"
req_grep 'Do not depend on GNU ld heading text' "tools/analyze_link_map.sh" "link-map analysis is independent from localized GNU ld headings"
req_grep 'BABET_ENABLE_SIZE_AUDIT' "CMakeLists.txt" "CMake has an opt-in size-audit switch"
req_grep '\-Wl,-Map=.*babet-link\.map' "CMakeLists.txt" "size audit emits a GNU linker map"
req_grep '\-\-size-audit' "build_local.sh" "maintainer build exposes --size-audit"
req_grep 'strip .*SIZE_BINARY' "build_local.sh" "size audit measures a stripped copy"
req_grep 'cannot be combined with sanitizers|incompatible.*sanit' "CMakeLists.txt" "size audit rejects sanitizer attribution"
req_grep 'NOT removable-size deltas|NOT removable-size' "tools/analyze_link_map.sh" "report rejects additive/removal interpretation"
req_grep 'one-feature-at-a-time differential builds' "tools/analyze_link_map.sh" "report defers exact cost to differential builds"
req_grep 'GUI bridge \(Babet code\)' "tools/analyze_link_map.sh" "GUI bridge has an attribution bucket"
req_grep 'SQLite' "tools/analyze_link_map.sh" "SQLite has an attribution bucket"
req_grep 'OpenSSL crypto/TLS \(shared\)' "tools/analyze_link_map.sh" "shared OpenSSL cost is labelled explicitly"
req_grep 'RE2/Abseil dependencies' "tools/analyze_link_map.sh" "RE2/Abseil has an attribution bucket"
req_grep 'C\+\+/GCC static runtime' "tools/analyze_link_map.sh" "static C++ runtime is separated from optional components"
req_grep 'ncursesw \(static dependency\)' "tools/analyze_link_map.sh" "ncursesw has an attribution bucket"
req_grep 'No public .*minimal.*standard.*full.*profiles are introduced|no public profile range is planned' "SIZE_PROFILES_STUDY.md" "study records that public profiles are not implemented"

echo "size/profile study contracts: ${PASS} PASS / ${FAIL} FAIL"
[[ ${FAIL} -eq 0 ]]
