#!/bin/bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [machine-architecture]" >&2
    exit 1
fi

ARCH="${1:-$(uname -m)}"
case "${ARCH}" in
    x86_64|amd64)
        printf '%s\n' 'linux-x86_64'
        ;;
    aarch64|arm64)
        printf '%s\n' 'linux-aarch64'
        ;;
    armv6l|armv7l|armhf)
        printf '%s\n' 'linux-armhf'
        ;;
    *)
        printf 'linux-%s\n' "${ARCH}"
        ;;
esac
