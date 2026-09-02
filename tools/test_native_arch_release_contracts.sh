#!/bin/bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${ROOT}/tools/run_native_arch_release_validation.sh"
PASS=0
FAIL=0

pass(){ echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail(){ echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
check(){ if eval "$1"; then pass "$2"; else fail "$2"; fi; }

check "[ -x '${RUNNER}' ]" "native architecture validation runner exists"
check "bash -n '${RUNNER}'" "native architecture validation runner shell syntax"
check "grep -Fq 'native-arch-validation.log' '${RUNNER}' && grep -Fq 'exec > >(tee' '${RUNNER}'" "runner keeps a complete stable console log automatically"
check "grep -Fq 'linux-aarch64|linux-armhf' '${RUNNER}'" "runner accepts the two required ARM release tags"
check "grep -Fq 'run_tests.sh\" --release' '${RUNNER}'" "runner executes the complete native pre-release campaign"
check "grep -Fq 'test_gc_sections_runtime.sh' '${RUNNER}'" "runner checks the adopted GC/OpenSSL contract on the real build"
check "grep -Fq 'test_tls_capabilities.sh' '${RUNNER}'" "runner replays the deterministic TLS capability matrix"
check "grep -Fq 'release.sh\"' '${RUNNER}'" "runner packages the already validated normal build"
check "grep -Fq 'test/babet and the CMake final binary are byte-identical before packaging' '${RUNNER}'" "runner proves the packaged build source matches the tested binary"
check "! grep -Fq 'release.sh\" --build' '${RUNNER}'" "runner does not rebuild a different binary during packaging"
check "grep -Fq 'sha256sum -c' '${RUNNER}'" "runner verifies release checksums"
check "grep -Fq 'Tag_ABI_VFP_args: VFP registers' '${RUNNER}'" "armhf validation checks the hard-float ABI"
check "grep -Fq 'packaged libbabet.a contains native' '${RUNNER}'" "runner validates the SDK archive architecture"
check "grep -Fq 'examples from the packaged SDK build and execute natively' '${RUNNER}'" "runner executes examples from the packaged SDK artifact"
check "grep -Fq -- '-DBABET_SDK_DIR=' '${RUNNER}'" "runner configures packaged SDK examples with the documented SDK variable"
check "grep -Fq 'binary inside release tarball differs' '${RUNNER}'" "runner compares tarball and standalone release binaries"
check "grep -Fq 'production_stripped_size=' '${RUNNER}'" "runner records the native stripped size"
check "grep -Fq 'production_sha256=' '${RUNNER}'" "runner records the native binary checksum"
check "grep -Fq 'status=PASS' '${RUNNER}'" "runner writes an explicit successful compact report"
check "grep -Fq -- '--resume-packaged' '${RUNNER}'" "runner exposes a bounded resume mode after completed packaging"
check "grep -Fq -- '--suspend-watchdog' '${RUNNER}'" "runner exposes explicit watchdog suspension"
check "grep -Fq '.babet-native-validation-watchdog.state' '${RUNNER}'" "runner persists watchdog restore state outside build/"
check "grep -Fq 'native_watchdog_restore_guard.sh' '${RUNNER}' && [ -x '${ROOT}/tools/native_watchdog_restore_guard.sh' ]" "runner delegates privileged restoration to a dedicated watchdog guard"
check "grep -Fq 'WATCHDOG_GUARD_READY' '${RUNNER}' && grep -Fq '/proc/\${guard_pid}' '${RUNNER}' && ! grep -Fq 'WATCHDOG_GUARD_PID' '${RUNNER}'" "runner handshakes with the real detached guard instead of trusting sudo launcher PID"
check "grep -Fq '.babet-native-validation-watchdog.state' '${ROOT}/.gitignore' && grep -Fq '.babet-native-validation-watchdog.restore' '${ROOT}/.gitignore' && grep -Fq '.babet-native-validation-watchdog.guard.ready' '${ROOT}/.gitignore'" "watchdog recovery scratch files are ignored by Git"
check "grep -Fq 'restore_watchdog_marker' '${RUNNER}' && grep -Fq 'trap cleanup_native_validation EXIT' '${RUNNER}'" "runner restores watchdog state on normal/signal exit and next startup"
check "grep -Fq 'watchdog_systemctl stop' '${RUNNER}' && ! grep -Eq 'systemctl (disable|mask)' '${RUNNER}'" "runner stops watchdog feeders without disabling or masking them"
check "grep -Fq 'watchdog matériel encore actif' '${RUNNER}'" "runner verifies hardware watchdog disarm when sysfs exposes state"
check "grep -Fq 'pre_release_sanitizers=' '${RUNNER}'" "compact native report records the sanitizer policy"
check "grep -Fq 'armv6l|armv7l|armhf' '${ROOT}/validate_release.sh' && grep -Fq -- '--ubsan' '${ROOT}/validate_release.sh'" "armhf release policy uses explicit UBSan-only validation"
check "grep -Fq 'Validation pré-release : OK' '${RUNNER}' && grep -Fq 'LOGGED_NORMAL_SHA' '${RUNNER}'" "resume binds successful pre-release evidence to the current normal binary SHA"
check "grep -Fq 'resume package is the exact stripped current validated build' '${RUNNER}'" "resume proves the existing package comes from the current validated build"
check "! grep -Eq 'ar t .*\|.*awk .*exit' '${RUNNER}'" "SDK member inspection avoids pipefail/SIGPIPE early-exit pipelines"

check "grep -Fq 'test_native_arch_release_contracts.sh' '${ROOT}/run_tests.sh'" "permanent test suite runs native architecture release contracts"
check "grep -Fq './tools/run_native_arch_release_validation.sh' '${ROOT}/ARCHITECTURE.md'" "English architecture overview documents the native release runner"
check "grep -Fq './tools/run_native_arch_release_validation.sh' '${ROOT}/ARCHITECTURE.fr.md'" "French architecture overview documents the native release runner"
check "grep -Fq 'linux-aarch64' '${ROOT}/BINARY_SIZE.md' && grep -Fq 'linux-armhf' '${ROOT}/BINARY_SIZE.md'" "binary-size history keeps separate native ARM rows"
check "grep -Fq 'native aarch64' '${ROOT}/todo' && grep -Fq 'linux-armhf' '${ROOT}/todo'" "roadmap tracks native ARM release validation"

if bash "${ROOT}/tools/test_native_watchdog_guard.sh"; then
    pass "watchdog restore guard passes its hermetic runtime regression"
else
    fail "watchdog restore guard passes its hermetic runtime regression"
fi

for pair in \
    'aarch64 linux-aarch64' \
    'arm64 linux-aarch64' \
    'armv6l linux-armhf' \
    'armv7l linux-armhf' \
    'armhf linux-armhf'; do
    set -- ${pair}
    actual="$(bash "${ROOT}/tools/release_arch_tag.sh" "$1" 2>/dev/null || true)"
    if [[ "${actual}" == "$2" ]]; then
        pass "release architecture helper maps $1 to $2"
    else
        fail "release architecture helper maps $1 to $2"
    fi
done

echo "native architecture release contracts: ${PASS} PASS / ${FAIL} FAIL"
[[ "${FAIL}" -eq 0 ]]
