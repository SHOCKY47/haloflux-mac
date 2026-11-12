#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
VERSION="$(cat VERSION)"
OUT="$ROOT/build"
mkdir -p "$OUT"
STAGE="$(mktemp -d "$OUT/.build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/HaloFlux.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/audio"
cp index.html wp.js workspace-palette.js orca-scene.js orca-scene.css LICENSE NOTICE "$APP/Contents/Resources/"
cp audio/sw421k.mp3 "$APP/Contents/Resources/audio/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HaloFlux</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleIdentifier</key><string>local.haloflux.desktop</string>
<key>CFBundleName</key><string>HaloFlux</string>
<key>CFBundleDisplayName</key><string>HaloFlux</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHumanReadableCopyright</key><string>HALOFLUX by Ryder191. macOS adaptation by SHOCKY47. Noncommercial use only.</string>
</dict></plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
  -module-cache-path "$OUT/module-cache" \
  -framework AppKit -framework WebKit \
  Sources/HaloFluxDesktop.swift Sources/HaloWebView.swift \
  Sources/OrcaStateBridge.swift Sources/OrcaModelMetadata.swift \
  Sources/OrcaAttentionMetadata.swift \
  -o "$APP/Contents/MacOS/HaloFlux"
codesign --force --sign - --identifier local.haloflux.desktop "$APP"
codesign --verify --deep --strict "$APP"
if [[ -e "$OUT/HaloFlux.app" ]]; then
  mv "$OUT/HaloFlux.app" "$STAGE/previous.app"
fi
mv "$APP" "$OUT/HaloFlux.app"
echo "Built $OUT/HaloFlux.app ($VERSION, Apple Silicon, macOS 13+)"

