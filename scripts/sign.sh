#!/bin/bash
# Signs an app bundle with a stable identity so macOS keeps its permissions (audio capture,
# Accessibility) across rebuilds. Falls back to ad-hoc signing if the identity isn't in the keychain.
# Usage: scripts/sign.sh <bundle.app>      Identity: $SIGN_IDENTITY (default "Flatroom Dev")
set -euo pipefail

APP="$1"
IDENTITY="${SIGN_IDENTITY:-Flatroom Dev}"

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
    echo "signed with '$IDENTITY'"
else
    codesign --force --sign - --timestamp=none "$APP"
    echo "signed ad-hoc (no '$IDENTITY' certificate: permissions will be asked again after each rebuild)"
fi
