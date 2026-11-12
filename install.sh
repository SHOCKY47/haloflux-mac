#!/bin/bash
# Installs only the desktop app and a per-user login job. No sudo or Python.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "HaloFlux v0.1 requires an Apple Silicon Mac. Run Terminal natively, without Rosetta." >&2
  exit 1
fi
if (( $(sw_vers -productVersion | cut -d. -f1) < 13 )); then
  echo "HaloFlux requires macOS 13 or later." >&2
  exit 1
fi
SOURCE="$ROOT/HaloFlux.app"
[[ -d "$SOURCE" ]] || SOURCE="$ROOT/build/HaloFlux.app"
if [[ ! -d "$SOURCE" ]]; then
  echo "HaloFlux.app not found. Download the release ZIP, or run bash build.sh first." >&2
  exit 1
fi
codesign --verify --deep --strict "$SOURCE"
APP_DIR="$HOME/Applications"
DEST="$APP_DIR/HaloFlux.app"
LABEL="local.haloflux.desktop.login"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$APP_DIR" "$HOME/Library/LaunchAgents"
STAGE="$(mktemp -d "$APP_DIR/.haloflux-install.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$SOURCE" "$STAGE/HaloFlux.app"
# Generate plist values with plutil so spaces and XML characters are escaped.
JOB="$STAGE/$LABEL.plist"
plutil -create xml1 "$JOB"
plutil -insert Label -string "$LABEL" "$JOB"
plutil -insert ProgramArguments -xml '<array/>' "$JOB"
plutil -insert ProgramArguments.0 -string /usr/bin/open "$JOB"
plutil -insert ProgramArguments.1 -string -g "$JOB"
plutil -insert ProgramArguments.2 -string "$DEST" "$JOB"
plutil -insert RunAtLoad -bool true "$JOB"
plutil -insert KeepAlive -bool false "$JOB"
plutil -insert LimitLoadToSessionType -string Aqua "$JOB"
plutil -insert ProcessType -string Interactive "$JOB"
plutil -insert StandardOutPath -string /dev/null "$JOB"
plutil -insert StandardErrorPath -string /dev/null "$JOB"
# Retain each previous installation for rollback; only stop our own app.
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN/$LABEL"
fi
pkill -x HaloFlux 2>/dev/null || true
if [[ -e "$DEST" ]]; then
  BACKUPS="$HOME/Library/Application Support/HaloFlux/Backups"
  mkdir -p "$BACKUPS"
  mv "$DEST" "$BACKUPS/HaloFlux-$(date +%Y%m%d-%H%M%S)-$$.app"
fi
mv "$STAGE/HaloFlux.app" "$DEST"
cp "$JOB" "$PLIST"
chmod 644 "$PLIST"
launchctl enable "$DOMAIN/$LABEL"
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Installed: $DEST"
echo "Starts automatically at GUI login. Look for the circle icon in the menu bar."
echo "If macOS blocks the first launch, use System Settings > Privacy & Security > Open Anyway."
echo "No system security settings have been changed."

