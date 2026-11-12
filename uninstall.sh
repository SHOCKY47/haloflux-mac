#!/bin/bash
set -euo pipefail
LABEL="local.haloflux.desktop.login"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN/$LABEL"
fi
pkill -x HaloFlux 2>/dev/null || true
if [[ -f "$PLIST" ]]; then rm "$PLIST"; fi
APP="$HOME/Applications/HaloFlux.app"
# Keep the app recoverable in Trash, and retain existing backups/preferences.
if [[ -e "$APP" ]]; then
  mkdir -p "$HOME/.Trash"
  mv "$APP" "$HOME/.Trash/HaloFlux-$(date +%Y%m%d-%H%M%S)-$$.app"
fi
echo "HaloFlux desktop and its login job have been removed. Backups and preferences are retained."

