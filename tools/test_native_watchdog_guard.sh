#!/bin/bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="${ROOT}/tools/native_watchdog_restore_guard.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/babet-watchdog-guard.XXXXXX")" || exit 1
trap 'rm -rf -- "${TMP}"' EXIT
PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/systemctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${BABET_FAKE_SYSTEMCTL_LOG}"
exit "${BABET_FAKE_SYSTEMCTL_RC:-0}"
SH
chmod +x "${TMP}/bin/systemctl"

if [ -x "${GUARD}" ] && bash -n "${GUARD}"; then
    pass "watchdog restore guard exists with valid shell syntax"
else
    fail "watchdog restore guard exists with valid shell syntax"
fi

STATE="${TMP}/state"
TRIGGER="${TMP}/trigger"
READY="${TMP}/ready"
LOG="${TMP}/systemctl.log"
printf 'version=1\nservice=watchdog.service\nservice=wd_keepalive.service\n' > "${STATE}"
: > "${TRIGGER}"
: > "${LOG}"
if PATH="${TMP}/bin:${PATH}" \
    BABET_FAKE_SYSTEMCTL_LOG="${LOG}" \
    BABET_WATCHDOG_GUARD_POLL_SECONDS=0.01 \
    bash "${GUARD}" "$$" "${STATE}" "${TRIGGER}" "${READY}" \
        watchdog.service wd_keepalive.service \
    && [ ! -e "${STATE}" ] && [ ! -e "${TRIGGER}" ] && [ ! -e "${READY}" ] \
    && [ "$(cat "${LOG}")" = $'start watchdog.service\nstart wd_keepalive.service' ]; then
    pass "guard restores the exact known services and clears persistent state"
else
    fail "guard restores the exact known services and clears persistent state"
fi

STATE_READY="${TMP}/state-ready"
TRIGGER_READY="${TMP}/trigger-ready"
READY_READY="${TMP}/ready-ready"
LOG_READY="${TMP}/systemctl-ready.log"
printf 'version=1\nservice=wd_keepalive.service\n' > "${STATE_READY}"
: > "${LOG_READY}"
PATH="${TMP}/bin:${PATH}" \
    BABET_FAKE_SYSTEMCTL_LOG="${LOG_READY}" \
    BABET_WATCHDOG_GUARD_POLL_SECONDS=0.01 \
    bash "${GUARD}" "$$" "${STATE_READY}" "${TRIGGER_READY}" "${READY_READY}" \
        wd_keepalive.service &
READY_GUARD_PID=$!
for _ in {1..50}; do
    [ -s "${READY_READY}" ] && break
    sleep 0.01
done
if [ -s "${READY_READY}" ] && grep -Eq '^[0-9]+$' "${READY_READY}"; then
    : > "${TRIGGER_READY}"
    if wait "${READY_GUARD_PID}" \
        && [ ! -e "${STATE_READY}" ] \
        && [ ! -e "${TRIGGER_READY}" ] \
        && [ ! -e "${READY_READY}" ] \
        && [ "$(cat "${LOG_READY}")" = 'start wd_keepalive.service' ]; then
        pass "guard publishes a real-process readiness handshake before waiting"
    else
        fail "guard publishes a real-process readiness handshake before waiting"
    fi
else
    : > "${TRIGGER_READY}"
    wait "${READY_GUARD_PID}" 2>/dev/null || true
    fail "guard publishes a real-process readiness handshake before waiting"
fi

STATE_DEAD="${TMP}/state-dead"
TRIGGER_DEAD="${TMP}/trigger-dead"
READY_DEAD="${TMP}/ready-dead"
LOG_DEAD="${TMP}/systemctl-dead.log"
printf 'version=1\nservice=wd_keepalive.service\n' > "${STATE_DEAD}"
: > "${LOG_DEAD}"
sleep 0.05 &
DEAD_PARENT=$!
if PATH="${TMP}/bin:${PATH}" \
    BABET_FAKE_SYSTEMCTL_LOG="${LOG_DEAD}" \
    BABET_WATCHDOG_GUARD_POLL_SECONDS=0.01 \
    bash "${GUARD}" "${DEAD_PARENT}" "${STATE_DEAD}" "${TRIGGER_DEAD}" "${READY_DEAD}" \
        wd_keepalive.service \
    && [ ! -e "${STATE_DEAD}" ] && [ ! -e "${READY_DEAD}" ] \
    && [ "$(cat "${LOG_DEAD}")" = 'start wd_keepalive.service' ]; then
    pass "guard restores automatically when the parent disappears"
else
    fail "guard restores automatically when the parent disappears"
fi

STATE_FAIL="${TMP}/state-fail"
TRIGGER_FAIL="${TMP}/trigger-fail"
READY_FAIL="${TMP}/ready-fail"
LOG_FAIL="${TMP}/systemctl-fail.log"
printf 'version=1\nservice=watchdog.service\n' > "${STATE_FAIL}"
: > "${TRIGGER_FAIL}"
: > "${LOG_FAIL}"
if PATH="${TMP}/bin:${PATH}" \
    BABET_FAKE_SYSTEMCTL_LOG="${LOG_FAIL}" \
    BABET_FAKE_SYSTEMCTL_RC=1 \
    bash "${GUARD}" "$$" "${STATE_FAIL}" "${TRIGGER_FAIL}" "${READY_FAIL}" watchdog.service \
        >/dev/null 2>&1; then
    fail "guard reports restoration failure"
else
    if [ -e "${STATE_FAIL}" ] && [ ! -e "${READY_FAIL}" ]; then
        pass "guard keeps persistent state when restoration fails"
    else
        fail "guard keeps persistent state when restoration fails"
    fi
fi

STATE_BAD="${TMP}/state-bad"
TRIGGER_BAD="${TMP}/trigger-bad"
READY_BAD="${TMP}/ready-bad"
printf 'version=1\nservice=evil.service\n' > "${STATE_BAD}"
: > "${TRIGGER_BAD}"
if PATH="${TMP}/bin:${PATH}" \
    BABET_FAKE_SYSTEMCTL_LOG="${LOG}" \
    bash "${GUARD}" "$$" "${STATE_BAD}" "${TRIGGER_BAD}" "${READY_BAD}" evil.service \
        >/dev/null 2>&1; then
    fail "guard rejects unknown service names"
else
    pass "guard rejects unknown service names"
fi

printf 'native watchdog restore guard: %d PASS / %d FAIL\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
