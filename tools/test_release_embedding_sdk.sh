#!/bin/bash
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_release_sdk.sh" "$@"
