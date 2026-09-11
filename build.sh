#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
packageRoot=$(mktemp -d "$PWD/.build/package.XXXXXX")
trap 'rm -rf "$packageRoot"' EXIT
appPath="$packageRoot/BearCompanion.app"
mkdir -p "$appPath/Contents/MacOS" "$appPath/Contents/Resources/Assets"
xcrun swiftc Sources/main.swift -o "$appPath/Contents/MacOS/BearCompanion" -framework AppKit -framework CoreGraphics -framework ImageIO -module-cache-path "$PWD/.build/module-cache" -target "$(uname -m)-apple-macosx13.0"
cp Info.plist "$appPath/Contents/Info.plist"
for assetPath in Assets/*.png Assets/*.webp; do
    if [ -f "$assetPath" ]; then cp "$assetPath" "$appPath/Contents/Resources/Assets/"; fi
done
codesign --force --sign - "$appPath"
"$appPath/Contents/MacOS/BearCompanion" --self-test --require-assets
# Publish fresh files rather than overwriting a signed executable in place.
if [ -d BearCompanion.app ]; then mv BearCompanion.app "$packageRoot/previous.app"; fi
mv "$appPath" BearCompanion.app
