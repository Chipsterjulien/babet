#!/bin/bash
# Contrats structurels de babet.find(..., { xdev = true }).
# Le test d'intégration réel vit dans la suite Lua et utilise /dev -> /dev/pts.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "${SCRIPT_DIR}" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
source = (root / "src/lua_bindings/find.cpp").read_text()
suite = (root / "examples/selftest/suites/filesystem/find_iterator.lua").read_text()
run_tests = (root / "run_tests.sh").read_text()
fr = (root / "docs/fr/modules/fs.md").read_text()
en = (root / "docs/en/modules/fs.md").read_text()

checks = []
def check(name, value):
    checks.append((name, bool(value)))

check("xdev defaults to disabled",
      re.search(r"bool\s+xdev\s*=\s*false", source))
check("xdev is parsed as a strict boolean",
      'read_optional_boolean("xdev", out.xdev)' in source
      and "' must be a boolean" in source)
check("xdev records the traversed root device",
      "::stat(root.c_str(), &root_stat)" in source
      and "root_device = root_stat.st_dev" in source)
check("xdev compares directory entries without following symlinks",
      "::lstat(it->path().c_str(), &entry_stat)" in source
      and "entry_stat.st_dev != root_device" in source)
check("xdev tolerates only disappearance races",
      re.search(r"lstat_errno\s*==\s*ENOENT.*?continue;", source, re.S)
      and "Every other error" in source)
check("xdev cancels pending recursion before skipping vanished directories",
      re.search(r"if\s*\(lstat_errno\s*==\s*ENOENT\)\s*\{.*?"
                r"disable_recursion_pending\(\);.*?continue;.*?\}",
                source, re.S))
check("xdev prunes with disable_recursion_pending",
      re.search(r"depth >= options\.maxdepth \|\| crosses_device.*?"
                r"disable_recursion_pending\(\)", source, re.S))
check("foreign mount points remain eligible for filters",
      re.search(r"if\s*\(entry_is_directory\s*&&\s*"
                r"\(depth >= options\.maxdepth \|\| crosses_device\)\)"
                r"\s*\{\s*it\.disable_recursion_pending\(\);\s*\}"
                r"\s*if\s*\(depth < options\.mindepth",
                source, re.S))
check("xdev introduces no pop-based iterator advancement",
      not re.search(r"^[ \t]*it\.pop\s*\(", source[source.find("std::optional<std::string> find("):], re.M))
check("Lua tests use a real devpts device boundary",
      'device_id("/dev")' in suite
      and 'device_id("/dev/pts")' in suite
      and 'dev_device ~= pts_device' in suite)
check("Lua tests prove pruning and mount-point visibility",
      "find xdev prunes foreign-device children" in suite
      and "find xdev keeps the foreign mount point visible" in suite
      and 'contains(unrestricted, "/dev/pts/ptmx")' in suite)
check("xdev is exercised inside a worker",
      "find xdev keeps identical worker semantics" in suite)
check("French and English contracts document xdev semantics",
      "xdev" in fr and "point de montage" in fr and "Sans `xdev`" in fr
      and "xdev" in en and "mount point" in en
      and re.search(r"Without\s+`xdev`", en))
check("documentation explains st_dev edge cases",
      "sous-volume Btrfs" in fr and "bind mount" in fr
      and "Btrfs subvolume" in en and "bind mount" in en)
check("release validation runs the xdev preflight",
      "tools/test_find_xdev_contracts.sh" in run_tests)

failed = [name for name, passed in checks if not passed]
for name, passed in checks:
    print(f"[{'PASS' if passed else 'FAIL'}] {name}")

if failed:
    raise SystemExit(1)
print(f"find xdev structural contracts: {len(checks)} PASS / 0 FAIL")
PY
