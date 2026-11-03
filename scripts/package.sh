#!/usr/bin/env bash
# Zips build/Sonata.app as build/Sonata-<version>.zip, with its SHA-256 beside it.
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Sonata.app/Contents/Info.plist)"
zip="build/Sonata-$version.zip"
rm -f "$zip" "$zip.sha256"
ditto -c -k --sequesterRsrc --keepParent build/Sonata.app "$zip"
(cd build && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256")
echo "$zip"
