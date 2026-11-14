#!/usr/bin/env bash
set -euo pipefail
# SDK 27's new State macro needs a SwiftUI compiler plug-in absent in this CLT.
# Use the selected Xcode SDK by default. Allow an explicit SDK override for
# environments that require a particular macOS SDK.
if [[ -n "${SYNOLOGY_NOTE_SDK:-}" ]]; then
    if [[ ! -d "$SYNOLOGY_NOTE_SDK" ]]; then
        echo "SDK not found: $SYNOLOGY_NOTE_SDK" >&2
        exit 1
    fi
    exec swift "$@" --build-system native --sdk "$SYNOLOGY_NOTE_SDK"
fi
exec swift "$@" --build-system native
