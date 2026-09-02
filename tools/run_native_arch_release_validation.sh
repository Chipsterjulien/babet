#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

RESUME_PACKAGED=0
SUSPEND_WATCHDOG=0
for arg in "$@"; do
    case "${arg}" in
        --resume-packaged)
            RESUME_PACKAGED=1
            ;;
        --suspend-watchdog)
            SUSPEND_WATCHDOG=1
            ;;
        -h|--help)
            echo "Usage: $0 [--resume-packaged] [--suspend-watchdog]"
            echo "  --resume-packaged   resume after a previously validated/package-complete native run"
            echo "  --suspend-watchdog  temporarily stop known active watchdog feeders and restore them on exit"
            exit 0
            ;;
        *)
            echo "ERREUR: option inconnue: ${arg}" >&2
            echo "Usage: $0 [--resume-packaged] [--suspend-watchdog]" >&2
            exit 2
            ;;
    esac
done

# Keep a complete stable log for long native runs. This is deliberately outside
# build/ so build cleanup/reconfiguration cannot erase the evidence mid-run.
NATIVE_VALIDATION_LOG="${ROOT}/native-arch-validation.log"
if [[ -z "${BABET_NATIVE_ARCH_LOG_ACTIVE:-}" ]]; then
    export BABET_NATIVE_ARCH_LOG_ACTIVE=1
    : > "${NATIVE_VALIDATION_LOG}"
    exec > >(tee "${NATIVE_VALIDATION_LOG}") 2>&1
fi

ARCH_RAW="$(uname -m)"
ARCH_TAG="$(bash "${ROOT}/tools/release_arch_tag.sh" "${ARCH_RAW}")"
REPORT_DIR="${ROOT}/build/native-arch-validation"
REPORT="${REPORT_DIR}/${ARCH_TAG}.txt"

case "${ARCH_TAG}" in
    linux-x86_64|linux-aarch64|linux-armhf)
        ;;
    *)
        echo "ERREUR: architecture native non couverte par cette campagne: ${ARCH_RAW} (${ARCH_TAG})" >&2
        echo "Cette validation ne doit pas être utilisée comme preuve ARM via cross-compilation." >&2
        exit 1
        ;;
esac

for tool in awk ar cmake ctest file grep ldd python3 readelf sha256sum stat strip tar; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "ERREUR: outil requis absent: ${tool}" >&2
        exit 1
    fi
done

mapfile -t CMAKE_VERSIONS < <(
    sed -nE \
        's/^[[:space:]]*project\([[:space:]]*babet[[:space:]]+VERSION[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+).*$/\1/p' \
        "${ROOT}/CMakeLists.txt"
)
if [[ "${#CMAKE_VERSIONS[@]}" -ne 1 ]]; then
    echo "ERREUR: version Babet CMake introuvable ou ambiguë." >&2
    exit 1
fi
VERSION="${CMAKE_VERSIONS[0]}"

print_stage() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

fail() {
    echo "[FAIL] $1" >&2
    exit 1
}

pass() {
    echo "[PASS] $1"
}

WATCHDOG_STATE_FILE="${ROOT}/.babet-native-validation-watchdog.state"
WATCHDOG_RESTORE_TRIGGER="${ROOT}/.babet-native-validation-watchdog.restore"
WATCHDOG_GUARD_READY="${ROOT}/.babet-native-validation-watchdog.guard.ready"
WATCHDOG_SERVICES=(watchdog.service wd_keepalive.service)
WATCHDOG_GUARD_ACTIVE=0
TMP=""

watchdog_systemctl() {
    if [[ "$(id -u)" -eq 0 ]]; then
        systemctl "$@"
    else
        sudo -n systemctl "$@"
    fi
}

watchdog_require_control() {
    command -v systemctl >/dev/null 2>&1 || {
        echo "ERREUR: systemctl absent alors qu'un watchdog doit être restauré/suspendu." >&2
        return 1
    }
    if [[ "$(id -u)" -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 || {
            echo "ERREUR: sudo absent ; impossible de contrôler le watchdog." >&2
            return 1
        }
        if ! sudo -n true >/dev/null 2>&1; then
            echo "ERREUR: droits sudo non préautorisés pour le watchdog." >&2
            echo "Exécuter 'sudo -v' avant ce runner, puis relancer la même commande." >&2
            return 1
        fi
    fi
}

watchdog_hardware_active() {
    local state_file state
    shopt -s nullglob
    local state_files=(/sys/class/watchdog/watchdog*/state)
    shopt -u nullglob
    for state_file in "${state_files[@]}"; do
        state="$(cat "${state_file}" 2>/dev/null || true)"
        if [[ "${state}" == "active" ]]; then
            return 0
        fi
    done
    return 1
}

watchdog_any_device_present() {
    compgen -G '/sys/class/watchdog/watchdog*' >/dev/null 2>&1
}

watchdog_read_marker_services() {
    local line service
    while IFS= read -r line; do
        case "${line}" in
            service=*)
                service="${line#service=}"
                case "${service}" in
                    watchdog.service|wd_keepalive.service)
                        printf '%s\n' "${service}"
                        ;;
                    *)
                        echo "ERREUR: service watchdog inconnu dans le marqueur : ${service}" >&2
                        return 1
                        ;;
                esac
                ;;
        esac
    done < "${WATCHDOG_STATE_FILE}"
}

restore_watchdog_marker() {
    local service restore_failed=0 all_active=1
    local -a services=()
    [[ -f "${WATCHDOG_STATE_FILE}" ]] || return 0

    echo "INFO: état watchdog persistant détecté ; restauration avant toute nouvelle validation."
    command -v systemctl >/dev/null 2>&1 || {
        echo "ERREUR: systemctl absent ; marqueur watchdog conservé." >&2
        return 1
    }
    if ! mapfile -t services < <(watchdog_read_marker_services); then
        return 1
    fi
    if [[ "${#services[@]}" -eq 0 ]]; then
        echo "ERREUR: marqueur watchdog sans service restaurable." >&2
        return 1
    fi

    # Après un reboot, systemd peut avoir déjà restauré les unités. Dans ce cas
    # aucun sudo n'est nécessaire : le marqueur devient simplement obsolète.
    for service in "${services[@]}"; do
        if ! systemctl is-active --quiet "${service}" 2>/dev/null; then
            all_active=0
            break
        fi
    done
    if [[ "${all_active}" -eq 1 ]]; then
        rm -f -- "${WATCHDOG_STATE_FILE}" "${WATCHDOG_RESTORE_TRIGGER}"
        echo "INFO: services watchdog déjà actifs ; marqueur persistant acquitté."
        return 0
    fi

    watchdog_require_control || return 1
    for service in "${services[@]}"; do
        if ! watchdog_systemctl start "${service}"; then
            echo "ERREUR: impossible de restaurer ${service}." >&2
            restore_failed=1
        fi
    done
    if [[ "${restore_failed}" -eq 0 ]]; then
        for service in "${services[@]}"; do
            if ! systemctl is-active --quiet "${service}" 2>/dev/null; then
                echo "ERREUR: ${service} n'est pas actif après restauration." >&2
                restore_failed=1
            fi
        done
    fi
    if [[ "${restore_failed}" -ne 0 ]]; then
        return 1
    fi

    rm -f -- "${WATCHDOG_STATE_FILE}" "${WATCHDOG_RESTORE_TRIGGER}" "${WATCHDOG_GUARD_READY}"
    return 0
}

watchdog_start_restore_guard() {
    local parent_pid="$$"
    local guard="${ROOT}/tools/native_watchdog_restore_guard.sh"
    local guard_pid="" attempt
    local -a services=("$@")

    [[ -x "${guard}" ]] || {
        echo "ERREUR: gardien watchdog absent/non exécutable : ${guard}" >&2
        return 1
    }
    command -v setsid >/dev/null 2>&1 || {
        echo "ERREUR: commande setsid absente ; impossible de détacher le gardien watchdog." >&2
        return 1
    }

    # Do not use $! as the guard identity here. sudo/setsid may fork and the
    # launcher PID can disappear while the detached privileged guard is alive.
    # The real guard therefore acknowledges readiness itself after validation.
    rm -f -- "${WATCHDOG_RESTORE_TRIGGER}" "${WATCHDOG_GUARD_READY}"
    if [[ "$(id -u)" -eq 0 ]]; then
        setsid "${guard}" "${parent_pid}" \
            "${WATCHDOG_STATE_FILE}" "${WATCHDOG_RESTORE_TRIGGER}" \
            "${WATCHDOG_GUARD_READY}" "${services[@]}" &
    else
        sudo -n setsid "${guard}" "${parent_pid}" \
            "${WATCHDOG_STATE_FILE}" "${WATCHDOG_RESTORE_TRIGGER}" \
            "${WATCHDOG_GUARD_READY}" "${services[@]}" &
    fi

    for attempt in {1..50}; do
        if [[ -s "${WATCHDOG_GUARD_READY}" ]]; then
            IFS= read -r guard_pid < "${WATCHDOG_GUARD_READY}" || true
            if [[ "${guard_pid}" =~ ^[0-9]+$ && -d "/proc/${guard_pid}" ]]; then
                WATCHDOG_GUARD_ACTIVE=1
                return 0
            fi
        fi
        sleep 0.1
    done

    rm -f -- "${WATCHDOG_GUARD_READY}"
    echo "ERREUR: le gardien root n'a pas confirmé son démarrage." >&2
    return 1
}

suspend_watchdog_if_requested() {
    local service active_count=0 marker_tmp
    local -a active_services=()

    if command -v systemctl >/dev/null 2>&1; then
        for service in "${WATCHDOG_SERVICES[@]}"; do
            if systemctl is-active --quiet "${service}" 2>/dev/null; then
                active_services+=("${service}")
                active_count=$((active_count + 1))
            fi
        done
    fi

    if [[ "${SUSPEND_WATCHDOG}" -eq 0 ]]; then
        if [[ "${ARCH_TAG}" == "linux-armhf" ]] \
            && { [[ "${active_count}" -gt 0 ]] || watchdog_hardware_active; }; then
            echo "AVERTISSEMENT: watchdog actif sur linux-armhf."
            echo "Le build sanitizer peut rendre un petit ARM indisponible assez longtemps pour déclencher un reset."
            echo "Relancer avec --suspend-watchdog après 'sudo -v' pour une validation longue protégée."
        fi
        return 0
    fi

    if [[ "${active_count}" -eq 0 ]] && ! watchdog_hardware_active; then
        if watchdog_any_device_present; then
            echo "INFO: watchdog présent mais inactif ; aucune suspension nécessaire."
        else
            echo "INFO: aucun watchdog détecté ; --suspend-watchdog est un no-op."
        fi
        return 0
    fi

    if [[ "${active_count}" -eq 0 ]] && watchdog_hardware_active; then
        echo "ERREUR: watchdog matériel actif mais aucun feeder connu n'est actif." >&2
        echo "Refus de fermer un propriétaire watchdog inconnu." >&2
        return 1
    fi

    watchdog_require_control || return 1

    echo
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "WATCHDOG — SUSPENSION TEMPORAIRE DEMANDÉE"
    echo "La compilation sanitizer peut saturer un petit ARM pendant très longtemps."
    echo "L'état actif est enregistré avant arrêt et sera restauré par un gardien root dédié."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

    marker_tmp="${WATCHDOG_STATE_FILE}.tmp.$$"
    {
        echo 'version=1'
        for service in "${active_services[@]}"; do
            echo "service=${service}"
        done
    } > "${marker_tmp}"
    mv -f -- "${marker_tmp}" "${WATCHDOG_STATE_FILE}"

    # Le gardien obtient ses privilèges maintenant, pendant que sudo est encore
    # autorisé. Il peut donc restaurer plusieurs heures plus tard, même si le
    # timestamp sudo expire ou si le runner reçoit SIGKILL.
    watchdog_start_restore_guard "${active_services[@]}" || return 1

    for service in "${active_services[@]}"; do
        watchdog_systemctl stop "${service}" || {
            echo "ERREUR: impossible d'arrêter ${service}." >&2
            return 1
        }
    done

    sleep 1
    for service in "${active_services[@]}"; do
        if systemctl is-active --quiet "${service}" 2>/dev/null; then
            echo "ERREUR: ${service} est encore actif après stop." >&2
            return 1
        fi
    done
    if watchdog_hardware_active; then
        echo "ERREUR: watchdog matériel encore actif après arrêt des feeders connus." >&2
        return 1
    fi

    pass "watchdog temporarily suspended with persistent restore state and root restore guard"
}

cleanup_native_validation() {
    local rc=$?
    trap - EXIT INT TERM HUP
    if [[ -n "${TMP:-}" && -d "${TMP}" ]]; then
        rm -rf -- "${TMP}"
    fi

    if [[ "${WATCHDOG_GUARD_ACTIVE:-0}" -eq 1 ]]; then
        local restore_seen=0 attempt
        : > "${WATCHDOG_RESTORE_TRIGGER}"
        # The privileged guard is intentionally detached and is not necessarily
        # a child of this shell after sudo/setsid. Observe the durable state
        # marker instead of wait(2)-ing on a launcher PID.
        for attempt in {1..120}; do
            if [[ ! -f "${WATCHDOG_STATE_FILE}" ]]; then
                restore_seen=1
                break
            fi
            sleep 0.25
        done
        WATCHDOG_GUARD_ACTIVE=0
        rm -f -- "${WATCHDOG_GUARD_READY}"
        if [[ "${restore_seen}" -eq 1 ]]; then
            echo "[PASS] watchdog state restored by root guard"
        else
            echo "ERREUR: le gardien root n'a pas acquitté le marqueur watchdog ; marqueur conservé : ${WATCHDOG_STATE_FILE}" >&2
            rc=1
        fi
    elif [[ -f "${WATCHDOG_STATE_FILE}" ]]; then
        if ! restore_watchdog_marker; then
            echo "ERREUR: la restauration du watchdog a échoué ; marqueur conservé : ${WATCHDOG_STATE_FILE}" >&2
            rc=1
        else
            echo "[PASS] watchdog state restored"
        fi
    fi
    exit "${rc}"
}

trap cleanup_native_validation EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# A stale marker means a previous run was killed before its EXIT trap. Restore
# the exact known-active services before doing anything expensive or suspending again.
restore_watchdog_marker || fail "cannot restore watchdog state left by a previous run"
suspend_watchdog_if_requested || fail "cannot establish the requested watchdog-safe state"

print_stage "Babet ${VERSION} — native architecture release validation"
echo "uname -m : ${ARCH_RAW}"
echo "arch tag : ${ARCH_TAG}"
if [[ "${ARCH_TAG}" == "linux-x86_64" ]]; then
    echo "INFO: x86_64 is a reference rerun only; it does not close the pending ARM rows."
fi

print_stage "1/7 — native architecture validation contracts"
bash "${ROOT}/tools/test_native_arch_release_contracts.sh"

BINARY="${ROOT}/test/babet"
BUILD_DIR="${ROOT}/build/project_build"
BUILT_BINARY="${BUILD_DIR}/babet"
PRE_RELEASE_LOG="${ROOT}/babet-tests.txt"
if [[ "${ARCH_TAG}" == "linux-armhf" ]]; then
    PRE_RELEASE_SANITIZERS="UBSAN_ONLY"
else
    PRE_RELEASE_SANITIZERS="ASAN_UBSAN"
fi

if [[ "${RESUME_PACKAGED}" -eq 0 ]]; then
    print_stage "2/7 — complete native pre-release campaign"
    bash "${ROOT}/run_tests.sh" --release
else
    print_stage "2/7 — validated pre-release evidence (resume)"
    [[ -f "${PRE_RELEASE_LOG}" ]] || fail "cannot resume: babet-tests.txt is missing"
    grep -Fq 'Validation pré-release : OK' "${PRE_RELEASE_LOG}" \
        || fail "cannot resume: babet-tests.txt does not contain a successful pre-release result"
fi

[[ -x "${BINARY}" ]] || fail "normal final Babet binary is missing after release validation"
[[ -x "${BUILT_BINARY}" ]] || fail "normal final CMake binary is missing after release validation"
CURRENT_BINARY_SHA="$(sha256sum "${BINARY}" | awk '{print $1}')"
if [[ "${CURRENT_BINARY_SHA}" != "$(sha256sum "${BUILT_BINARY}" | awk '{print $1}')" ]]; then
    fail "test/babet and build/project_build/babet differ before packaging"
fi
pass "test/babet and the CMake final binary are byte-identical before packaging"

if [[ "${RESUME_PACKAGED}" -eq 1 ]]; then
    LOGGED_NORMAL_SHA="$(awk '/^SHA-256[[:space:]]*:/ { sha=$3 } END { print sha }' "${PRE_RELEASE_LOG}")"
    [[ -n "${LOGGED_NORMAL_SHA}" ]] || fail "cannot resume: normal binary SHA is absent from babet-tests.txt"
    [[ "${LOGGED_NORMAL_SHA}" == "${CURRENT_BINARY_SHA}" ]] \
        || fail "cannot resume: current normal binary does not match the validated babet-tests.txt SHA"
    pass "resume evidence SHA matches the current normal binary"
fi

print_stage "3/7 — adopted GC/OpenSSL contract on the native final build"
bash "${ROOT}/tools/test_gc_sections_runtime.sh" "${BINARY}" "${BUILD_DIR}"

print_stage "4/7 — deterministic native TLS capability matrix"
bash "${ROOT}/tools/test_tls_capabilities.sh" "${BINARY}"

print_stage "5/7 — package the exact validated native build"
if [[ "${RESUME_PACKAGED}" -eq 0 ]]; then
    bash "${ROOT}/release.sh"
else
    echo "Resume: reuse existing release artifacts after identity/checksum verification."
fi

DIST="${ROOT}/dist"
BASE="babet-${VERSION}-${ARCH_TAG}"
RELEASE_BINARY="${DIST}/${BASE}"
RELEASE_BINARY_SHA="${RELEASE_BINARY}.sha256"
RELEASE_TARBALL="${DIST}/${BASE}.tar.gz"
RELEASE_TARBALL_SHA="${RELEASE_TARBALL}.sha256"
SDK_BASE="babet-${VERSION}-${ARCH_TAG}-sdk"
SDK_TARBALL="${DIST}/${SDK_BASE}.tar.gz"
SDK_TARBALL_SHA="${SDK_TARBALL}.sha256"

for path in \
    "${RELEASE_BINARY}" "${RELEASE_BINARY_SHA}" \
    "${RELEASE_TARBALL}" "${RELEASE_TARBALL_SHA}" \
    "${SDK_TARBALL}" "${SDK_TARBALL_SHA}"; do
    [[ -f "${path}" ]] || fail "missing release artifact: ${path}"
done
pass "all native release and SDK artifacts exist"

(
    cd "${DIST}"
    sha256sum -c "$(basename "${RELEASE_BINARY_SHA}")" >/dev/null
    sha256sum -c "$(basename "${RELEASE_TARBALL_SHA}")" >/dev/null
    sha256sum -c "$(basename "${SDK_TARBALL_SHA}")" >/dev/null
) || fail "one or more release checksums do not verify"
pass "binary, release tarball and SDK checksums verify"

if [[ "${RESUME_PACKAGED}" -eq 1 ]]; then
    RESUME_TMP="$(mktemp -d "${TMPDIR:-/tmp}/babet-native-resume.XXXXXX")"
    cp -- "${BINARY}" "${RESUME_TMP}/expected-release-binary"
    strip --strip-all "${RESUME_TMP}/expected-release-binary"
    if [[ "$(sha256sum "${RESUME_TMP}/expected-release-binary" | awk '{print $1}')" != "$(sha256sum "${RELEASE_BINARY}" | awk '{print $1}')" ]]; then
        rm -rf -- "${RESUME_TMP}"
        fail "cannot resume: packaged release binary is not the stripped current validated build"
    fi
    rm -rf -- "${RESUME_TMP}"
    pass "resume package is the exact stripped current validated build"
fi

print_stage "6/7 — ELF/SDK architecture and packaged-artifact validation"
FILE_OUTPUT="$(LC_ALL=C file -b "${RELEASE_BINARY}")"
ELF_HEADER="$(LC_ALL=C readelf -h "${RELEASE_BINARY}")"

if ! grep -Fq 'stripped' <<<"${FILE_OUTPUT}"; then
    fail "release binary is not reported as stripped"
fi
pass "release binary is stripped"

case "${ARCH_TAG}" in
    linux-x86_64)
        grep -Eq 'Class:[[:space:]]+ELF64' <<<"${ELF_HEADER}" || fail "x86_64 release is not ELF64"
        grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' <<<"${ELF_HEADER}" || fail "x86_64 ELF machine mismatch"
        ;;
    linux-aarch64)
        grep -Eq 'Class:[[:space:]]+ELF64' <<<"${ELF_HEADER}" || fail "aarch64 release is not ELF64"
        grep -Eq 'Machine:[[:space:]]+AArch64' <<<"${ELF_HEADER}" || fail "aarch64 ELF machine mismatch"
        ;;
    linux-armhf)
        grep -Eq 'Class:[[:space:]]+ELF32' <<<"${ELF_HEADER}" || fail "armhf release is not ELF32"
        grep -Eq 'Machine:[[:space:]]+ARM' <<<"${ELF_HEADER}" || fail "armhf ELF machine mismatch"
        LC_ALL=C readelf -A "${RELEASE_BINARY}" | grep -Fq 'Tag_ABI_VFP_args: VFP registers' \
            || fail "ARM release does not advertise the hard-float VFP calling convention"
        ;;
esac
pass "release ELF class/machine matches ${ARCH_TAG}"

LDD_OUTPUT="$(LC_ALL=C ldd "${RELEASE_BINARY}" 2>&1 || true)"
if grep -Fq 'not found' <<<"${LDD_OUTPUT}"; then
    printf '%s\n' "${LDD_OUTPUT}" >&2
    fail "release has an unresolved dynamic dependency"
fi
if grep -Eqi 'lib(ssl|crypto|archive|zstd|lzma|bz2|re2|absl|ncurses|tinfo|sqlite3|gtk|gobject|glib|stdc\+\+|gcc_s)' <<<"${LDD_OUTPUT}"; then
    printf '%s\n' "${LDD_OUTPUT}" >&2
    fail "release unexpectedly depends dynamically on a bundled/runtime-sensitive library"
fi
pass "release has no unexpected bundled/GUI/C++ runtime dynamic dependency"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/babet-native-arch-sdk.XXXXXX")"

tar -xzf "${SDK_TARBALL}" -C "${TMP}"
SDK_ROOT="${TMP}/${SDK_BASE}"
for rel in \
    include/babet/babet.h include/babet/plugin.h lib/libbabet.a \
    README.txt LICENSE THIRD_PARTY_NOTICES.md examples/embedding/CMakeLists.txt; do
    [[ -f "${SDK_ROOT}/${rel}" ]] || fail "packaged SDK is missing ${rel}"
done
pass "packaged SDK contains headers, libbabet, docs/notices and examples"

if ! SDK_MEMBERS="$(ar t "${SDK_ROOT}/lib/libbabet.a")"; then
    fail "cannot list packaged SDK libbabet.a members"
fi
FIRST_MEMBER="$(awk 'NF { print; exit }' <<<"${SDK_MEMBERS}")"
[[ -n "${FIRST_MEMBER}" ]] || fail "packaged SDK libbabet.a has no archive member"
ar p "${SDK_ROOT}/lib/libbabet.a" "${FIRST_MEMBER}" > "${TMP}/sdk-first-member.o"
SDK_ELF_HEADER="$(LC_ALL=C readelf -h "${TMP}/sdk-first-member.o")"
case "${ARCH_TAG}" in
    linux-x86_64)
        grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' <<<"${SDK_ELF_HEADER}" || fail "SDK archive member is not x86_64"
        ;;
    linux-aarch64)
        grep -Eq 'Machine:[[:space:]]+AArch64' <<<"${SDK_ELF_HEADER}" || fail "SDK archive member is not AArch64"
        ;;
    linux-armhf)
        grep -Eq 'Machine:[[:space:]]+ARM' <<<"${SDK_ELF_HEADER}" || fail "SDK archive member is not ARM"
        ;;
esac
pass "packaged libbabet.a contains native ${ARCH_TAG} objects"

cmake -S "${SDK_ROOT}/examples/embedding" -B "${TMP}/examples-build" \
    -DBABET_SDK_DIR="${SDK_ROOT}" >/dev/null
cmake --build "${TMP}/examples-build" -j2 >/dev/null
ctest --test-dir "${TMP}/examples-build" --output-on-failure
pass "examples from the packaged SDK build and execute natively"

TAR_BIN="${TMP}/release-bin"
tar -xOf "${RELEASE_TARBALL}" "${BASE}/babet" > "${TAR_BIN}"
if [[ "$(sha256sum "${TAR_BIN}" | awk '{print $1}')" != "$(sha256sum "${RELEASE_BINARY}" | awk '{print $1}')" ]]; then
    fail "binary inside release tarball differs from standalone release binary"
fi
pass "release tarball contains the exact standalone stripped binary"

print_stage "7/7 — compact native architecture report"
mkdir -p "${REPORT_DIR}"
STRIPPED_SIZE="$(stat -c '%s' "${RELEASE_BINARY}")"
BINARY_SHA256="$(sha256sum "${RELEASE_BINARY}" | awk '{print $1}')"
TARBALL_SHA256="$(sha256sum "${RELEASE_TARBALL}" | awk '{print $1}')"
SDK_SHA256="$(sha256sum "${SDK_TARBALL}" | awk '{print $1}')"
OPENSSL_BIN="${ROOT}/build/openssl/openssl-3.5.8/apps/openssl"
OPENSSL_VERSION="$(${OPENSSL_BIN} version 2>/dev/null || true)"
COMPILER_VERSION="$(c++ --version | head -n1)"
LD_VERSION="$(ld --version | head -n1)"

cat > "${REPORT}" <<EOF_REPORT
status=PASS
project_version=${VERSION}
native_uname_m=${ARCH_RAW}
arch_tag=${ARCH_TAG}
compiler=${COMPILER_VERSION}
linker=${LD_VERSION}
openssl=${OPENSSL_VERSION}
production_stripped_size=${STRIPPED_SIZE}
production_sha256=${BINARY_SHA256}
release_tarball_sha256=${TARBALL_SHA256}
sdk_tarball_sha256=${SDK_SHA256}
release_binary=$(basename "${RELEASE_BINARY}")
release_tarball=$(basename "${RELEASE_TARBALL}")
sdk_tarball=$(basename "${SDK_TARBALL}")
pre_release_validation=PASS
pre_release_sanitizers=${PRE_RELEASE_SANITIZERS}
gc_openssl_contract=PASS
tls_matrix=7_PASS_0_FAIL_0_SKIP
packaged_sdk_examples=PASS
run_tests_log=babet-tests.txt
tls_report=build/openssl-study/tls-capabilities.txt
EOF_REPORT

cat "${REPORT}"
echo
if [[ "${ARCH_TAG}" == "linux-aarch64" || "${ARCH_TAG}" == "linux-armhf" ]]; then
    echo "Native ARM result ready for BINARY_SIZE.md / roadmap closure."
else
    echo "Reference x86_64 rerun complete; ARM roadmap still requires aarch64 + armhf."
fi
echo "Report: ${REPORT}"
