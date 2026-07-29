#!/usr/bin/env bash
#
# live-chrome-login.sh — Open the live browser for a group in headed (visible)
# mode so you can sign into sites, then restart the headless service.
#
# The live browser normally runs as a headless systemd service so the agent can
# use the DevTools port. This script handles the stop/start around a sign-in
# session:
#
#   1. Stops the group's nanoclaw-live-chrome-<group>.service if it's running.
#   2. Opens Chromium in headed (visible) mode on the same persistent profile,
#      at an optional start URL.
#   3. When you close the browser window, restarts the service automatically.
#
# You only need this when signing in for the first time, re-authenticating after
# a session expires, or approving 2FA. Normal agent browsing uses the headless
# service and requires no interaction.
#
# Usage:
#   bash scripts/live-chrome-login.sh <group> [start-url]
#   bash scripts/live-chrome-login.sh rs-work-pa https://accounts.google.com
#
set -euo pipefail

GROUP="${1:?usage: live-chrome-login.sh <group> [start-url]}"
START_URL="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

UNIT="nanoclaw-live-chrome-${GROUP}.service"

# Stop the service so we can open the headed browser on the same profile.
# (Two Chromium instances cannot share the same user-data-dir.)
SERVICE_WAS_RUNNING=0
if systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
  SERVICE_WAS_RUNNING=1
  echo "Stopping ${UNIT}..."
  systemctl --user stop "$UNIT"
  echo "  stopped."
else
  echo "(${UNIT} is not running)"
fi

echo
echo "Opening headed browser for group: ${GROUP}"
echo "Sign in to whatever sites you need, then close the window."
echo

# Run live-chrome.sh in login mode (headed, no remote-debugging-port).
# LIVE_CHROME_LOGIN suppresses the "use live-chrome-login.sh" tip in live-chrome.sh.
LIVE_CHROME_HEADLESS=0 LIVE_CHROME_LOGIN=1 bash "$SCRIPT_DIR/live-chrome.sh" "$GROUP" ${START_URL:+"$START_URL"}

# Browser closed — restart the service.
echo
if [[ "$SERVICE_WAS_RUNNING" == "1" ]]; then
  echo "Browser closed. Restarting ${UNIT}..."
  systemctl --user start "$UNIT"
  echo "  started. The agent can use the live browser again."
else
  echo "Browser closed. ${UNIT} was not running before this session;"
  echo "start it with: systemctl --user start ${UNIT}"
fi
