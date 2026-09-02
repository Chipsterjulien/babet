#!/bin/bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
pass(){ echo "[PASS] $1"; PASS=$((PASS+1)); }
fail(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
contains(){ grep -Fq -- "$2" "$1" && pass "$3" || fail "$3"; }

contains "$ROOT/CMakeLists.txt" 'BABET_SIZE_EXPERIMENT_NO_SQLITE' 'SQLite differential switch exists'
contains "$ROOT/CMakeLists.txt" 'BABET_SIZE_EXPERIMENT_NO_FIND_RE2' 'find/RE2 differential switch exists'
contains "$ROOT/CMakeLists.txt" 'BABET_SIZE_EXPERIMENT_NO_NETWORK' 'network differential switch exists'
contains "$ROOT/CMakeLists.txt" 'BABET_SIZE_EXPERIMENT_NO_ARCHIVE_COMPRESSION' 'archive/compression differential switch exists'
contains "$ROOT/CMakeLists.txt" 'BABET_SIZE_EXPERIMENT_NO_OPENSSL_HASHING' 'OpenSSL-backed hashing differential switch exists'
contains "$ROOT/CMakeLists.txt" 'set(BABET_SQLITE_AMALGAMATION)' 'SQLite amalgamation can be excluded'
contains "$ROOT/src/lua_bindings/sqlite.hpp" 'inline bool is_sqlite_null(lua_State *, int) noexcept { return false; }' 'SQLite sentinel has an experiment-only stub'
contains "$ROOT/src/project_core/runtime_registration.cpp" '#ifndef BABET_SIZE_EXPERIMENT_NO_NETWORK' 'network registration can be omitted'
contains "$ROOT/src/main.cpp" '#ifndef BABET_SIZE_EXPERIMENT_NO_ARCHIVE_COMPRESSION' 'archive version probes can be omitted'
contains "$ROOT/src/project_core/runtime_registration.cpp" '#ifndef BABET_SIZE_EXPERIMENT_NO_OPENSSL_HASHING' 'OpenSSL-backed hash registration can be omitted'
contains "$ROOT/CMakeLists.txt" 'BABET_SIZE_EXPERIMENT_NO_NETWORK AND' 'OpenSSL link omission requires network removal'
contains "$ROOT/CMakeLists.txt" 'BABET_SIZE_EXPERIMENT_NO_OPENSSL_HASHING)' 'OpenSSL link omission also requires hashing removal'
contains "$ROOT/tools/measure_size_deltas.sh" 'without-sqlite' 'differential runner measures SQLite'
contains "$ROOT/tools/measure_size_deltas.sh" 'without-find-re2' 'differential runner measures find/RE2'
contains "$ROOT/tools/measure_size_deltas.sh" 'without-network' 'differential runner measures network'
contains "$ROOT/tools/measure_size_deltas.sh" 'without-archive-compression' 'differential runner measures archive/compression'
contains "$ROOT/tools/measure_size_deltas.sh" 'without-hashing' 'differential runner measures hashing alone'
contains "$ROOT/tools/measure_size_deltas.sh" 'without-network-hashing' 'differential runner measures network plus hashing synergy'
contains "$ROOT/tools/measure_size_deltas.sh" 'without-four-large' 'differential runner measures the four-large combined build'
contains "$ROOT/tools/measure_size_deltas.sh" 'without-four-large-hashing' 'differential runner measures the current light-builder floor'
contains "$ROOT/tools/measure_size_deltas.sh" 'Do not sum the one-feature rows' 'differential report preserves non-additive warning'
contains "$ROOT/SIZE_PROFILES_STUDY.md" '| `without-network` | 13,405,672 | 2,153,824 | 13.84% |' 'study records first real network delta'
contains "$ROOT/SIZE_PROFILES_STUDY.md" '`without-network-hashing`' 'study documents OpenSSL synergy experiment'
contains "$ROOT/SIZE_PROFILES_STUDY.md" '`without-four-large`' 'study documents combined light-builder experiment'
contains "$ROOT/SIZE_PROFILES_STUDY.md" '3,830,560' 'study records the Candidate 8 experimental floor'
contains "$ROOT/SIZE_PROFILES_STUDY.md" 'No public `minimal` / `standard` / `full` profiles' 'study records the no-public-profiles decision'

if grep -Eq 'BABET_(BUILD_)?PROFILE_(MINIMAL|STANDARD|FULL)' "$ROOT/CMakeLists.txt"; then
    fail 'CMake still does not introduce named product profiles'
else
    pass 'CMake still does not introduce named product profiles'
fi

echo "size differential contracts: ${PASS} PASS / ${FAIL} FAIL"
[ "$FAIL" -eq 0 ]
