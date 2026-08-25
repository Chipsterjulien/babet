#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

python3 - "${ROOT_DIR}" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
harness = (root / "examples/selftest/harness.lua").read_text()
packaging = (root / "examples/selftest/suites/packaging.lua").read_text()
embedded_limits = (root / "examples/selftest/suites/embedded_limits.lua").read_text()
workers = (root / "examples/selftest/suites/workers/core.lua").read_text()
run_tests = (root / "run_tests.sh").read_text()

checks = []

def check(label, condition):
    checks.append((label, bool(condition)))

check("harness exposes explicit per-test categories",
      "ok_in" in harness and "category_stats" in harness)
check("harness reports common/folder/embedded/single-run categories",
      all(token in harness for token in (
          '"common"', '"folder"', '"embedded"', '"single-run"')))
check("folder arg contracts are classified as folder-only",
      re.search(r'ok_in\("folder",\s*"folder mode:', packaging) is not None)
check("packaged arg contracts are classified as embedded-only",
      re.search(r'ok_in\("embedded",\s*"packaged mode:', packaging) is not None)
check("create-exe publication contracts are classified as folder-only",
      re.search(r'ok_in\("folder",\s*"LOT 1 create-exe:', packaging) is not None)
check("embedded ZIP limit contracts are classified as folder-only",
      re.search(r'ok_in\("folder",\s*"LOT 3 ZIP limit:', embedded_limits) is not None)
check("workers node-limit regression is classified as single-run",
      re.search(r'ok_in\("single-run",\s*"workers budget: spawn args hits node limit"', workers) is not None)
count_delta_line = re.compile(
    r'(?=.*(?:folder|dossier|embedded|embarqué))(?=.*\b(?:13|14)\b)'
    r'(?=.*(?:PASS|tests?|écart|diff(?:erence|érence)?))',
    re.IGNORECASE)
check("run_tests contains no hard-coded folder/embedded PASS delta",
      not any(count_delta_line.search(line) for line in run_tests.splitlines()))
check("run_tests validates that category sums explain each total",
      "validate_selftest_accounting" in run_tests
      and "accounted=$((common + folder + embedded + single_run))" in run_tests)
check("run_tests compares common counts dynamically across execution modes",
      "validate_cross_mode_selftest_accounting" in run_tests
      and 'folder_common=$(selftest_category_pass "${folder_output}" "common")' in run_tests
      and 'embedded_common=$(selftest_category_pass "${embedded_output}" "common")' in run_tests
      and 'selftest_category_pass "${embedded_path_output}" "common"' in run_tests)
check("self-test summary prints category accounting",
      "Résultat par catégorie" in harness and "[%s]" in harness)

failures = 0
for label, passed in checks:
    print(f"[{'PASS' if passed else 'FAIL'}] {label}")
    failures += not passed

print(f"self-test accounting contracts: {len(checks) - failures} PASS / {failures} FAIL")
if failures:
    raise SystemExit(1)
PY
