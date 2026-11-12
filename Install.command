#!/bin/bash
ROOT="$(cd "$(dirname "$0")" && pwd)"
STATUS=0
bash "$ROOT/install.sh" || STATUS=$?
printf '\n'
read -r -p 'Press Return to close. '
exit "$STATUS"

