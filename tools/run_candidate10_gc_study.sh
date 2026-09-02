#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "============================================================"
echo "Babet Candidate 10 — section garbage-collection study"
echo "============================================================"
echo

echo "==> Candidate 10 contracts"
bash "${ROOT}/tools/test_candidate10_contracts.sh"

echo
echo "==> Fresh OpenSSL 3.5.8 size-audit baseline"
bash "${ROOT}/build_local.sh" --size-audit

echo
echo "==> Exact baseline runtime surface"
bash "${ROOT}/tools/test_runtime_surface.sh" "${ROOT}/test/babet"

echo
echo "==> Existing archive section audit"
bash "${ROOT}/tools/audit_gc_section_inputs.sh"

echo
echo "==> A/B/C stripped-size measurement"
bash "${ROOT}/tools/measure_gc_sections.sh"

echo
echo "==> Targeted runtime validation for A/B/C"
bash "${ROOT}/tools/test_candidate10_variants.sh"

echo
echo "============================================================"
echo "Candidate 10 measurement suite completed"
echo "============================================================"
echo "Send back:"
echo "  build/gc-sections-study/report.txt"
echo "  build/gc-sections-study/archive-section-audit.txt"
echo "  build/gc-sections-study/runtime-validation.txt"
echo "  build/gc-sections-study/variant-a-print-gc-sections.txt"
