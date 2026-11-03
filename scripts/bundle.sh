#!/usr/bin/env bash
# Builds build/Sonata.app.
#
#   VERSION=0.1.42        stamps the bundle's version (default: VERSION file + ".0")
#   UNIVERSAL=1           builds for Apple silicon and Intel
#   SIGN_IDENTITY="…"     signs with that identity and the hardened runtime, as notarization
#                         requires (default: ad hoc)
set -euo pipefail
cd "$(dirname "$0")/.."

version="${VERSION:-$(tr -d '[:space:]' < VERSION).0}"
archs=()
if [[ "${UNIVERSAL:-}" == 1 ]]; then archs=(--arch arm64 --arch x86_64); fi

swift build -c release --product Sonata ${archs[@]+"${archs[@]}"}
bin="$(swift build -c release --show-bin-path ${archs[@]+"${archs[@]}"})/Sonata"

app=build/Sonata.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Sonata"
cp Resources/Info.plist "$app/Contents/Info.plist"
# The icon: Icon Composer's .icon compiled into Assets.car (macOS 26 draws icons from it) plus
# AppIcon.icns for older systems.
xcrun actool Resources/AppIcon.icon --compile "$app/Contents/Resources" --platform macosx \
  --minimum-deployment-target 15.0 --app-icon AppIcon --include-all-app-icons \
  --output-partial-info-plist "$app/Contents/icon-info.plist" >/dev/null
rm "$app/Contents/icon-info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${version##*.}" "$app/Contents/Info.plist"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
else
  codesign --force --sign - "$app"
fi
codesign --verify --strict "$app"
echo "Built $app $version ($(lipo -archs "$app/Contents/MacOS/Sonata"))"
