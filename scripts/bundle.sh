#!/usr/bin/env bash
# Builds a release binary and wraps it into build/Sonata.app (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Sonata
APP=build/Sonata.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Sonata" "$APP/Contents/MacOS/Sonata"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
