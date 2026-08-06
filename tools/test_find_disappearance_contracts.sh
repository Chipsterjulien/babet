#!/usr/bin/env bash
# Contrats structurels de la robustesse babet.find() 2.21.1 face aux
# disparitions concurrentes. Le test d'exécution déterministe est séparé dans
# test_find_disappearing_directory.sh et s'exécute après chaque build.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "${SCRIPT_DIR}" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
source = (root / "src/lua_bindings/find.cpp").read_text()
runtime = (root / "tools/test_find_disappearing_directory.sh").read_text()
run_tests = (root / "run_tests.sh").read_text()
fr = (root / "docs/fr/modules/fs.md").read_text()
en = (root / "docs/en/modules/fs.md").read_text()

checks = []
def check(name, value):
    checks.append((name, bool(value)))

find_body = source[source.find("std::optional<std::string> find("):
                   source.find("} // namespace")]

check("find uses an explicit directory-iterator stack",
      "struct DirectoryFrame" in find_body
      and "std::vector<DirectoryFrame> stack" in find_body)
check("legacy recursive_directory_iterator construction is removed",
      not re.search(r"fs::recursive_directory_iterator\s*\(", find_body))
check("parent iteration advances before child descent",
      re.search(r"frame\.current\.increment\(advance_ec\).*?"
                r"fs::directory_iterator child\(entry\.path\(\), child_ec\)",
                find_body, re.S))
check("child opens use the non-throwing error-code overload",
      "fs::directory_iterator child(entry.path(), child_ec)" in find_body)
check("ENOENT child-open races stay local",
      re.search(r"if \(child_ec ==.*?no_such_file_or_directory.*?continue;",
                find_body, re.S))
check("other child-open errors remain fatal",
      "return path_error(\"cannot traverse directory\"" in find_body)
check("a vanished active frame resumes at its parent",
      re.search(r"advance_ec ==.*?no_such_file_or_directory.*?"
                r"stack\.pop_back\(\);.*?continue;", find_body, re.S))
check("directory symlinks remain non-followed",
      re.search(r"may_descend\s*=\s*"
                r"entry_is_directory\s*&&\s*!entry_is_symlink", find_body))
check("type matching reuses race-safe cached classification",
      "matches_options(entry, entry_is_regular," in find_body
      and "bool entry_is_regular" in source)
check("runtime regression covers glibc directory-open variants",
      "int openat(int dirfd" in runtime
      and "int openat64(int dirfd" in runtime
      and "int __openat_2(int dirfd" in runtime
      and "int __openat64_2(int dirfd" in runtime
      and "int open(const char *path" in runtime
      and "int open64(const char *path" in runtime
      and "DIR *opendir(const char *path)" in runtime
      and "DIR *fdopendir(int fd)" in runtime)
check("runtime regression removes the first opened child",
      "BABET_TEST_FIND_VANISH_ROOT" in runtime
      and "first_child_under_root" in runtime
      and "maybe_vanish" in runtime
      and "rmdir(target)" in runtime)
check("runtime regression checks marker write results",
      "static int write_all(" in runtime
      and "const int write_rc = write_all(" in runtime
      and "const int close_rc = close(marker_fd);" in runtime
      and "(void)write(marker_fd" not in runtime)
check("runtime regression proves later-sibling preservation",
      "expected two surviving sibling files" in runtime
      and "both later siblings remain visible" in runtime
      and "FOUND:${VICTIM}/payload.txt" in runtime)
check("release validation runs structural and runtime checks",
      "tools/test_find_disappearance_contracts.sh" in run_tests
      and "tools/test_find_disappearing_directory.sh" in run_tests)
check("French and English manuals document the race contract",
      "pile explicite" in fr and "dossier disparaît" in fr
      and "explicit stack" in en and "directory disappears" in en)

failed = [name for name, passed in checks if not passed]
for name, passed in checks:
    print(f"[{'PASS' if passed else 'FAIL'}] {name}")
if failed:
    raise SystemExit(1)
print(f"find disappearance structural contracts: {len(checks)} PASS / 0 FAIL")
PY
