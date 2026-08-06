#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MAIN="${PROJECT_DIR}/examples/main.lua"

python3 - "${PROJECT_DIR}" "${MAIN}" <<'PY'
from pathlib import Path
import re
import sys

project = Path(sys.argv[1])
main = Path(sys.argv[2])
examples = project / "examples"

errors = []
main_text = main.read_text(encoding="utf-8")
main_lines = main_text.count("\n")
main_bytes = len(main_text.encode("utf-8"))

if main_lines > 300:
    errors.append(f"examples/main.lua has {main_lines} lines (maximum: 300)")
if main_bytes > 32768:
    errors.append(f"examples/main.lua has {main_bytes} bytes (maximum: 32768)")
if "selftest.suites" not in main_text:
    errors.append("examples/main.lua no longer loads the modular suite registry")

module_ref_re = re.compile(r"[\"'](selftest(?:\.[A-Za-z0-9_]+)+)[\"']")

def resolve(module):
    rel = Path(*module.split("."))
    direct = examples / rel.with_suffix(".lua")
    package = examples / rel / "init.lua"
    if direct.is_file():
        return direct
    if package.is_file():
        return package
    return None

queue = ["selftest.harness", "selftest.suites"]
seen_modules = set()
seen_files = set()
while queue:
    module = queue.pop(0)
    if module in seen_modules:
        continue
    seen_modules.add(module)
    path = resolve(module)
    if path is None:
        errors.append(f"required self-test module is missing: {module}")
        continue
    seen_files.add(path.resolve())
    text = path.read_text(encoding="utf-8")
    queue.extend(module_ref_re.findall(text))

suite_root = examples / "selftest" / "suites"
all_suite_files = {p.resolve() for p in suite_root.rglob("*.lua")}
unreachable = sorted(all_suite_files - seen_files)
for path in unreachable:
    errors.append(f"unreachable self-test module: {path.relative_to(project)}")

for path in sorted(all_suite_files):
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()

    # In Lua, a newline does not necessarily terminate a statement. A
    # parenthesized IIFE following another expression can silently become a
    # chained call. Require an explicit semicolon before every such top-level
    # separator used by the extracted suites.
    for index, line in enumerate(lines):
        if not line.lstrip().startswith("(function"):
            continue
        previous = index - 1
        while previous >= 0:
            stripped = lines[previous].strip()
            if stripped and not stripped.startswith("--"):
                break
            previous -= 1
        if previous >= 0 and not lines[previous].rstrip().endswith(";"):
            errors.append(
                f"{path.relative_to(project)}:{index + 1} starts a "
                "parenthesized function without an explicit statement "
                "separator")

    line_count = text.count("\n")
    byte_count = len(text.encode("utf-8"))
    if line_count > 2500:
        errors.append(
            f"{path.relative_to(project)} has {line_count} lines (maximum: 2500)")
    if byte_count > 196608:
        errors.append(
            f"{path.relative_to(project)} has {byte_count} bytes (maximum: 196608)")

if errors:
    for error in errors:
        print(f"[FAIL] {error}")
    raise SystemExit(1)

print(f"[PASS] main.lua: {main_lines} lines / {main_bytes} bytes")
print(f"[PASS] {len(all_suite_files)} reachable suite modules")
print("[PASS] parenthesized suite statements have explicit separators")
print("[PASS] no suite exceeds the anti-monolith limits")
PY
