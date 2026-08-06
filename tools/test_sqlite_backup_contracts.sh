#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

python3 - "${PROJECT_DIR}" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
sqlite = (root / "src/lua_bindings/sqlite.cpp").read_text(encoding="utf-8")
helper = (root / "src/lua_bindings/sqlite_backup_file.cpp").read_text(encoding="utf-8")
tests = (root / "examples/selftest/suites/sqlite/backup.lua").read_text(encoding="utf-8")
registry = (root / "examples/selftest/suites/sqlite/init.lua").read_text(encoding="utf-8")

checks = []

def check(label, condition):
    checks.append((label, bool(condition)))

check("db:backup is registered through the SQLite exception boundary",
      "sqlite_lua_boundary<db_backup>" in sqlite)
check("backup uses sqlite3_backup_init/step/finish",
      all(token in sqlite for token in (
          "sqlite3_backup_init", "sqlite3_backup_step", "sqlite3_backup_finish")))
check("backup finish is owned by an RAII guard",
      re.search(r"~BackupHandleGuard\(\).*?sqlite3_backup_finish",
                sqlite, re.S) is not None)
check("SQLite handle guards expose their matching output-pointer types",
      re.search(r"class SqliteHandleGuard.*?sqlite3 \*\*out\(\) noexcept \{ return &handle_; \}",
                sqlite, re.S) is not None
      and re.search(r"class SqliteStatementGuard.*?sqlite3_stmt \*\*out\(\) noexcept \{ return &handle_; \}",
                    sqlite, re.S) is not None)
check("backup deadline uses steady_clock and is created outside the step loop",
      "using Clock = std::chrono::steady_clock" in sqlite
      and sqlite.find("const auto deadline") < sqlite.find("for (;;)" , sqlite.find("int db_backup")))
check("active source busy timeout is read, disabled and restored",
      'sqlite3_prepare_v2(handle, "PRAGMA busy_timeout"' in sqlite
      and "source_busy_timeout.disable" in sqlite
      and "source_busy_timeout.restore" in sqlite)
check("deadline is rechecked after sleep before another SQLite step",
      "sleep_for(actual_sleep)" in sqlite
      and "not begin another SQLite step once the global deadline passed" in sqlite
      and "now >= deadline" in sqlite
      and "Clock::now() >= deadline" in sqlite)
check("destination SQLite configuration return codes are checked",
      re.search(r"rc = sqlite3_extended_result_codes\(.*?if \(rc != SQLITE_OK\)",
                sqlite, re.S) is not None
      and re.search(r"rc = sqlite3_busy_timeout\(destination_db\.get\(\), 0\);.*?if \(rc != SQLITE_OK\)",
                    sqlite, re.S) is not None)
check("destination is written through a private same-directory temporary",
      ".babet-sqlite-backup-" in helper
      and "O_CREAT | O_EXCL" in helper
      and "/proc/self/fd/" in helper)
check("destination publication is atomic and no-overwrite is race-safe",
      "renameat(" in helper and "linkat(" in helper)
check("failed backups remove temporary database and SQLite sidecars",
      "cleanup_temporary_best_effort" in helper
      and all(suffix in helper for suffix in ("-journal", "-wal", "-shm")))
check("SQLite backup regression suite is reachable",
      'selftest.suites.sqlite.backup' in registry)
check("backup tests cover timeout, BUSY, WAL concurrency and restoration",
      all(token in tests for token in (
          "timeout=0 is a real non-blocking attempt",
          "SQLITE_BUSY",
          "WAL backup tolerates concurrent committed writes",
          "can itself be restored")))

failures = 0
for label, passed in checks:
    if passed:
        print(f"[PASS] {label}")
    else:
        print(f"[FAIL] {label}")
        failures += 1

print(f"SQLite backup structural contracts: {len(checks) - failures} PASS / {failures} FAIL")
raise SystemExit(1 if failures else 0)
PY
