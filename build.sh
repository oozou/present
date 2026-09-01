#!/bin/zsh
# Builds Present.app into ./build. Run once, then: open build/Present.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Present.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Present "$APP/Contents/MacOS/Present"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so TCC (camera permission) works reliably.
codesign --force --sign - "$APP"

echo "Built $APP"
