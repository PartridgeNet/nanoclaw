#!/usr/bin/env bash
#
# tesco-chrome.sh — Launch the dedicated Chrome instance meal-planner drives.
#
# This opens a brand-new, ISOLATED Chrome profile ($HOME/tesco-chrome) with
# nothing else logged in, exposing the DevTools port (loopback only) that
# scripts/tesco-chrome-bridge.mjs forwards into the meal-planner container.
#
# First run: log into Tesco in the window that opens (username, password, OTP,
# tick "remember me"). That session lives only in this profile and persists, so
# you rarely have to re-auth. Leave the window running whenever you want
# meal-planner to be able to shop.
#
# Usage:
#   bash scripts/tesco-chrome.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PROFILE="${TESCO_CHROME_PROFILE:-$HOME/tesco-chrome}"
DEBUG_PORT="${TESCO_CHROME_PORT:-9222}"
BRIDGE_PORT="${TESCO_BRIDGE_PORT:-9223}"
BRIDGE_LOG="${TESCO_BRIDGE_LOG:-$HOME/tesco-chrome-bridge.log}"

if [[ ! -x "$CHROME" ]]; then
  echo "Google Chrome not found at: $CHROME" >&2
  exit 1
fi

# Ensure the host-side DevTools bridge is running (meal-planner's container
# reaches Chrome through it). It's session-independent (nohup) and idempotent —
# if something is already listening on the bridge port we leave it alone.
if lsof -nP -iTCP:"$BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Bridge already running on port $BRIDGE_PORT."
else
  echo "Starting Chrome DevTools bridge on port $BRIDGE_PORT (log: $BRIDGE_LOG)"
  BRIDGE_PORT="$BRIDGE_PORT" CHROME_PORT="$DEBUG_PORT" \
    nohup node "$SCRIPT_DIR/tesco-chrome-bridge.mjs" >>"$BRIDGE_LOG" 2>&1 &
  disown || true
fi

echo "Launching dedicated Tesco Chrome"
echo "  profile:    $PROFILE"
echo "  debug port: $DEBUG_PORT (loopback only)"
echo
echo "Log into Tesco in the window that opens. Leave it running for meal-planner."

exec "$CHROME" \
  --user-data-dir="$PROFILE" \
  --remote-debugging-port="$DEBUG_PORT" \
  --remote-allow-origins='*' \
  --no-first-run \
  --no-default-browser-check \
  https://www.tesco.com
