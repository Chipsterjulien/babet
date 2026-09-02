#!/bin/bash
# Compatibility alias for trees updated in place from Babet 2.23.0.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/package_sdk.sh" "$@"
