#!/bin/bash
# Builds TapTest and wraps it in an .app bundle so macOS can attribute the
# "system audio recording" permission to it (a bare CLI would inherit the terminal's).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product TapTest
APP=build/TapTest.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/TapTest "$APP/Contents/MacOS/TapTest"
cp Resources/TapTest-Info.plist "$APP/Contents/Info.plist"
scripts/sign.sh "$APP"
echo "built $APP"
