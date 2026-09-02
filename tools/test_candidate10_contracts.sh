#!/bin/bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
pass(){ echo "[PASS] $1"; PASS=$((PASS+1)); }
fail(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
has(){ if grep -Fq -- "$2" "$1"; then pass "$3"; else fail "$3"; fi; }
not_has(){ if grep -Fq -- "$2" "$1"; then fail "$3"; else pass "$3"; fi; }

has "$ROOT/CMakeLists.txt" 'option(BABET_ENABLE_GC_SECTIONS' "Candidate 10 linker-GC lever is now the production option"
has "$ROOT/CMakeLists.txt" 'option(BABET_SIZE_EXPERIMENT_GC_BABET_SECTIONS' "Babet section split remains independently opt-in"
has "$ROOT/CMakeLists.txt" 'BABET_SIZE_EXPERIMENT_GC_BABET_SECTIONS requires BABET_ENABLE_GC_SECTIONS' "Babet split still requires linker GC"
has "$ROOT/CMakeLists.txt" 'target_link_options(${PROJECT_NAME} PRIVATE -Wl,--gc-sections)' "validated variant A linker GC is adopted"
has "$ROOT/CMakeLists.txt" 'COMPILE_OPTIONS -ffunction-sections -fdata-sections' "historical variant B remains measurable"
has "$ROOT/build_local.sh" '-ffunction-sections' "validated OpenSSL section split is adopted"
has "$ROOT/build_local.sh" '-fdata-sections' "validated OpenSSL data split is adopted"
has "$ROOT/build_local.sh" '-DBABET_ENABLE_GC_SECTIONS=ON' "normal product explicitly enables linker GC"
not_has "$ROOT/build_local.sh" 'BABET_SIZE_EXPERIMENT_GC_BABET_SECTIONS=ON' "rejected Babet source split is not adopted"
has "$ROOT/tools/measure_gc_sections.sh" 'THRESHOLD=$((256 * 1024))' "256 KiB decision threshold remains recorded"
has "$ROOT/tools/measure_gc_sections.sh" 'build_variant variant-a' "variant A remains historically reproducible"
has "$ROOT/tools/measure_gc_sections.sh" 'build_variant variant-b' "variant B remains historically reproducible"
has "$ROOT/tools/measure_gc_sections.sh" 'build_variant variant-c' "variant C remains historically reproducible"
has "$ROOT/tools/measure_gc_sections.sh" './Configure no-shared --openssldir=/etc/ssl -ffunction-sections -fdata-sections' "historical C uses the measured OpenSSL split"
has "$ROOT/tools/measure_gc_sections.sh" 'marginal_vs_A' "B marginal gain is reported"
has "$ROOT/tools/measure_gc_sections.sh" 'marginal_vs_B' "C marginal gain is reported"
has "$ROOT/tools/test_runtime_surface.lua" 'unexpected babet top-level entry' "runtime surface guard rejects unexpected entries"
has "$ROOT/tools/test_runtime_surface.lua" 'missing babet top-level entry' "runtime surface guard rejects missing registrations"
has "$ROOT/tools/test_candidate10_variants.sh" 'test_native_plugin_runtime.sh' "all historical variants protect native plugin runtime"
has "$ROOT/tools/test_candidate10_variants.sh" 'tests/test_packaging.sh' "all historical variants protect --create-exe"
has "$ROOT/tools/test_candidate10_variants.sh" 'test_tls_capabilities.sh' "all historical variants protect deterministic TLS capabilities"
has "$ROOT/GC_SECTIONS_STUDY.md" 'Variant A' "English study documents A/B/C separation"
has "$ROOT/GC_SECTIONS_STUDY.fr.md" 'Variante A' "French study documents A/B/C separation"

for f in "$ROOT/tools/audit_gc_section_inputs.sh" "$ROOT/tools/measure_gc_sections.sh" "$ROOT/tools/test_runtime_surface.sh" "$ROOT/tools/test_candidate10_variants.sh" "$ROOT/tools/run_candidate10_gc_study.sh"; do
    if bash -n "$f"; then pass "shell syntax: ${f##*/}"; else fail "shell syntax: ${f##*/}"; fi
done

echo "Candidate 10 contracts: ${PASS} PASS / ${FAIL} FAIL"
[ "${FAIL}" -eq 0 ]
