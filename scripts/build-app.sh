#!/bin/bash
# Builds the menu bar app. Filters live in ~/Library/Application Support/Flatroom/Filters.
# Usage: scripts/build-app.sh [--install]   (--install copies it to ~/Applications and relaunches it)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Flatroom
APP=build/Flatroom.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Flatroom "$APP/Contents/MacOS/Flatroom"
cp Resources/Flatroom-Info.plist "$APP/Contents/Info.plist"
scripts/sign.sh "$APP"
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications/Flatroom.app"
    pkill -x Flatroom 2>/dev/null && sleep 1 || true
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "installed and launched $DEST"
fi
