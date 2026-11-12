#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(cat VERSION)"
bash build.sh
DIST="$ROOT/dist"
NAME="HaloFlux-v$VERSION-macOS-arm64"
mkdir -p "$DIST"
STAGE="$(mktemp -d "$DIST/.package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
BUNDLE="$STAGE/$NAME"
mkdir -p "$BUNDLE"
ditto "$ROOT/build/HaloFlux.app" "$BUNDLE/HaloFlux.app"
cp Install.command Uninstall.command install.sh uninstall.sh LICENSE NOTICE "$BUNDLE/"
cp docs/QUICK-START.txt "$BUNDLE/START-HERE.txt"
chmod +x "$BUNDLE/Install.command" "$BUNDLE/Uninstall.command" "$BUNDLE/install.sh" "$BUNDLE/uninstall.sh"
codesign --verify --deep --strict "$BUNDLE/HaloFlux.app"
# Only the explicit desktop bundle and installer files enter the archive.
ditto -c -k --norsrc --keepParent "$BUNDLE" "$DIST/$NAME.zip"
cd "$DIST"
shasum -a 256 "$NAME.zip" > SHA256SUMS.txt
echo "Packaged: $DIST/$NAME.zip"
cat SHA256SUMS.txt
