#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HEADER="${PROJECT_DIR}/src/lua_bindings/nofollow_path.hpp"
COPYTREE="${PROJECT_DIR}/src/lua_bindings/copyTree.cpp"
MOVETREE="${PROJECT_DIR}/src/lua_bindings/moveTree.cpp"
SECURE_DESTINATION="${PROJECT_DIR}/src/lua_bindings/secure_destination.cpp"
RUN_TESTS="${PROJECT_DIR}/run_tests.sh"

pass_count=0
fail_count=0
pass(){ echo "[PASS] $1"; pass_count=$((pass_count + 1)); }
fail(){ echo "[FAIL] $1"; fail_count=$((fail_count + 1)); }
check(){ if "$@"; then pass "${LABEL}"; else fail "${LABEL}"; fi; }

# Test the path helper as behaviour, not as an exact source spelling. This keeps
# the regression useful across harmless refactors of the implementation.
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
cat > "${tmpdir}/nofollow_path_test.cpp" <<'CPP'
#include "src/lua_bindings/nofollow_path.hpp"
#include <filesystem>
#include <iostream>
#include <string>
#include <utility>
#include <vector>

int main() {
    const std::vector<std::pair<std::string, std::string>> cases = {
        {"link/", "link"},
        {"link/./", "link"},
        {"link/././", "link"},
        {"/a/link/.", "/a/link"},
        {"a/b/..", "a/b/.."},
        {"link/..", "link/.."},
        {".", "."},
        {"/", "/"},
        {"//", "//"},
        {"a/.hidden", "a/.hidden"},
        {"a/..b", "a/..b"},
    };
    for (const auto& [input, expected] : cases) {
        const std::string actual = nofollow_final_component_path(std::filesystem::path(input)).string();
        if (actual != expected) {
            std::cerr << input << " -> " << actual << " (expected " << expected << ")\n";
            return 1;
        }
    }
    return 0;
}
CPP

if "${CXX:-c++}" -std=c++23 -Wall -Wextra -Wpedantic -Werror \
    -I"${PROJECT_DIR}" "${tmpdir}/nofollow_path_test.cpp" -o "${tmpdir}/nofollow_path_test" \
    && "${tmpdir}/nofollow_path_test"; then
    pass "terminal-component helper preserves the required path semantics"
else
    fail "terminal-component helper preserves the required path semantics"
fi

python3 - "${COPYTREE}" "${MOVETREE}" "${SECURE_DESTINATION}" "${RUN_TESTS}" <<'PY'
from pathlib import Path
import re
import sys

copytree, movetree, secure_destination, run_tests = [
    Path(path).read_text(encoding="utf-8") for path in sys.argv[1:]
]
checks = []
def check(name, condition): checks.append((name, bool(condition)))
def calls(text, arg):
    return re.search(r"\bnofollow_final_component_path\s*\(\s*" + re.escape(arg) + r"\s*\)", text) is not None

def direct_symlink_status(text, arg):
    return re.search(r"\bsymlink_status\s*\(\s*" + re.escape(arg) + r"\s*[,)]", text) is not None

check("copyTree uses the terminal-component guard for its user source root", calls(copytree, "source"))
check("moveTree uses the terminal-component guard for both user roots", calls(movetree, "source") and calls(movetree, "destination"))
check("SecureDestination uses the terminal-component guard for its user root", calls(secure_destination, "root"))
check("copyTree does not inspect the unguarded source root directly", not direct_symlink_status(copytree, "source"))
check("moveTree does not inspect unguarded source/destination roots directly", not direct_symlink_status(movetree, "source") and not direct_symlink_status(movetree, "destination"))
check("SecureDestination does not inspect the unguarded root directly", not direct_symlink_status(secure_destination, "root"))
check("top-level validation runs the filesystem symlink contract", "tools/test_filesystem_symlink_contracts.sh" in run_tests)

for name, ok in checks:
    print(f"[{'PASS' if ok else 'FAIL'}] {name}")
if any(not ok for _, ok in checks):
    raise SystemExit(1)
print(f"filesystem symlink structural contracts: {len(checks)} PASS / 0 FAIL")
PY

echo "filesystem symlink contract total: $((pass_count + 7)) PASS / ${fail_count} FAIL"
[ "${fail_count}" -eq 0 ]
