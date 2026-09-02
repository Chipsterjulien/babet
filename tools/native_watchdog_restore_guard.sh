#!/bin/bash
# Internal helper for run_native_arch_release_validation.sh.
# The caller grants root privileges before launching this process. The helper
# then waits for either the parent runner to disappear (including SIGKILL) or a
# normal-exit trigger, restores only the two known watchdog feeder units, and
# removes the persistent restore marker only after successful restoration.

set -u

if [ "$#" -lt 5 ]; then
    echo "Usage: $0 parent-pid state-file trigger-file ready-file service [...]" >&2
    exit 2
fi

PARENT_PID="$1"
STATE_FILE="$2"
TRIGGER_FILE="$3"
READY_FILE="$4"
shift 4
SERVICES=("$@")
POLL_SECONDS="${BABET_WATCHDOG_GUARD_POLL_SECONDS:-2}"

case "${PARENT_PID}" in
    ''|*[!0-9]*)
        echo "ERREUR: PID parent invalide: ${PARENT_PID}" >&2
        exit 2
        ;;
esac

for service in "${SERVICES[@]}"; do
    case "${service}" in
        watchdog.service|wd_keepalive.service)
            ;;
        *)
            echo "ERREUR: service watchdog non autorisé: ${service}" >&2
            exit 2
            ;;
    esac
done

command -v systemctl >/dev/null 2>&1 || {
    echo "ERREUR: systemctl absent dans le gardien watchdog." >&2
    exit 1
}

# A detached/background helper must not disappear when the caller loses its TTY.
trap '' HUP

# Handshake from the real privileged process. The runner must not infer our
# lifetime from the sudo/setsid launcher PID because that process may fork/exit.
printf '%s\n' "$$" > "${READY_FILE}" || exit 1

while kill -0 "${PARENT_PID}" 2>/dev/null && [ ! -e "${TRIGGER_FILE}" ]; do
    sleep "${POLL_SECONDS}"
done

restore_failed=0
for service in "${SERVICES[@]}"; do
    if ! systemctl start "${service}"; then
        echo "ERREUR: restauration watchdog échouée: ${service}" >&2
        restore_failed=1
    fi
done

if [ "${restore_failed}" -ne 0 ]; then
    rm -f -- "${READY_FILE}"
    exit 1
fi

rm -f -- "${STATE_FILE}" "${TRIGGER_FILE}" "${READY_FILE}"
exit 0
