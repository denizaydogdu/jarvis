#!/usr/bin/env bash
# Builds build/Jarvis.app (ad-hoc signed) and build/jarvis-hook from a release build.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

swift build -c release

app="build/Jarvis.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/JarvisApp "$app/Contents/MacOS/JarvisApp"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --deep -s - "$app"

cp .build/release/jarvis-hook build/jarvis-hook

echo "Built $(pwd)/$app and $(pwd)/build/jarvis-hook"
