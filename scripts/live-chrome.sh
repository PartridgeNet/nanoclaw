#!/usr/bin/env bash
#
# live-chrome.sh — Launch a dedicated live, headed Chrome that a NanoClaw agent
# group drives over CDP (via its `chrome-devtools` MCP server), for any site
# that needs a real, persistent, logged-in browser: sites with strong bot
# detection, or accounts where exported cookie sessions get rejected (e.g.
# Google — device-bound session checks reject transferred cookies, so a real
# headed browser you sign into is the only path that holds).
#
# General, one profile per group: an isolated, persistent Chrome profile that
# YOU sign into. The agent drives it through the host-side DevTools bridge
# (scripts/tesco-chrome-bridge.mjs). For plain anonymous browsing the agent
# still has its in-container `agent-browser`.
#
# Ports: the bridge port is read from the group's own chrome-devtools MCP config
# (`--browserUrl http://host.docker.internal:<port>`), so the launcher and the
# container always agree. Chrome's debug port defaults to <bridge_port - 1>.
# Override either with LIVE_BRIDGE_PORT / LIVE_CHROME_PORT.
#
# Logins persist in the profile, so you sign in once per site and rarely
# re-auth. Sign into as many sites as you like in the one window, and leave it
# running whenever you want the agent to browse as you.
#
# Usage:
#   bash scripts/live-chrome.sh <group> [start-url]
#   bash scripts/live-chrome.sh nathan-barley https://photos.google.com
#
set -euo pipefail

GROUP="${1:?usage: live-chrome.sh <group> [start-url]}"
START_URL="${2:-about:blank}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PROFILE="${LIVE_CHROME_PROFILE:-$HOME/.nanoclaw-live-chrome/$GROUP}"

if [[ ! -x "$CHROME" ]]; then
  echo "Google Chrome not found at: $CHROME" >&2
  exit 1
fi

# Resolve the bridge port from the group's chrome-devtools MCP config unless
# overridden — single source of truth so launcher and container never drift.
BRIDGE_PORT="${LIVE_BRIDGE_PORT:-}"
if [[ -z "$BRIDGE_PORT" ]]; then
  BRIDGE_PORT="$(cd "$REPO_ROOT" && node -e '
    const D = require("better-sqlite3");
    const db = new D("data/v2.db");
    const g = process.argv[1];
    const row = db.prepare(
      "SELECT cc.mcp_servers FROM container_configs cc JOIN agent_groups ag ON ag.id = cc.agent_group_id WHERE ag.name = ? OR ag.folder = ? OR ag.id = ?"
    ).get(g, g, g);
    if (!row) { process.stderr.write(`no container config for group: ${g}\n`); process.exit(2); }
    const cd = JSON.parse(row.mcp_servers)["chrome-devtools"];
    const url = ((cd && cd.args) || []).find((a) => /^https?:\/\//.test(a)) || "";
    const m = url.match(/:(\d+)/);
    if (!m) { process.stderr.write(`group ${g} has no chrome-devtools MCP browserUrl port; set LIVE_BRIDGE_PORT\n`); process.exit(3); }
    process.stdout.write(m[1]);
  ' "$GROUP")"
fi
CHROME_PORT="${LIVE_CHROME_PORT:-$((BRIDGE_PORT - 1))}"
BRIDGE_LOG="${LIVE_BRIDGE_LOG:-$HOME/.nanoclaw-live-chrome/$GROUP-bridge.log}"
mkdir -p "$(dirname "$BRIDGE_LOG")" "$PROFILE"

# Ensure the host-side DevTools bridge is running for this group's port. It's
# session-independent (nohup) and idempotent — if something is already
# listening on the bridge port we leave it alone.
if lsof -nP -iTCP:"$BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Bridge already running on port $BRIDGE_PORT."
else
  echo "Starting Chrome DevTools bridge on port $BRIDGE_PORT (log: $BRIDGE_LOG)"
  BRIDGE_PORT="$BRIDGE_PORT" CHROME_PORT="$CHROME_PORT" \
    nohup node "$SCRIPT_DIR/tesco-chrome-bridge.mjs" >>"$BRIDGE_LOG" 2>&1 &
  disown || true
fi

echo "Launching live Chrome for group: $GROUP"
echo "  profile:    $PROFILE"
echo "  debug port: $CHROME_PORT (loopback only)  ->  bridge $BRIDGE_PORT"
echo "  start URL:  $START_URL"
echo
echo "Sign into whatever sites you want '$GROUP' to use (approve any 2FA)."
echo "Logins persist in this profile. Leave the window running while it browses."

exec "$CHROME" \
  --user-data-dir="$PROFILE" \
  --remote-debugging-port="$CHROME_PORT" \
  --remote-allow-origins='*' \
  --no-first-run \
  --no-default-browser-check \
  "$START_URL"
