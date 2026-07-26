#!/usr/bin/env bash
#
# install-live-chrome-autostart.sh — Register a launchd LaunchAgent per live
# agent browser so each group's dedicated Chrome comes back automatically when
# the host restarts (logs in).
#
# A "live browser" group is one whose container config has a chrome-devtools
# MCP server pointing at a host bridge (`--browserUrl http://host.docker.internal:<port>`)
# — i.e. it drives a real headed Chrome on this Mac via scripts/live-chrome.sh.
# Groups whose chrome-devtools MCP has no browserUrl launch their own in-container
# browser and are skipped (nothing on the host to start).
#
# Each agent runs `scripts/live-chrome.sh <group>`, which also (idempotently)
# starts that group's host-side DevTools bridge. Plists land in
# ~/Library/LaunchAgents/com.nanoclaw.live-chrome.<group>.plist and, being
# user LaunchAgents, are loaded automatically at every login/restart.
#
# Usage:
#   bash scripts/install-live-chrome-autostart.sh              # write + validate plists (take effect next login)
#   bash scripts/install-live-chrome-autostart.sh --start-now  # also load + launch them right now
#
set -euo pipefail

START_NOW=0
[[ "${1:-}" == "--start-now" ]] && START_NOW=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LA_DIR="$HOME/Library/LaunchAgents"
NODE_BIN="$(command -v node)"
NODE_DIR="$(dirname "$NODE_BIN")"
PLIST_PATH="$NODE_DIR:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin"
mkdir -p "$LA_DIR" "$HOME/.nanoclaw-live-chrome"

# Discover live-browser groups (folder names) that have a bridge browserUrl.
LIVE_GROUPS="$(cd "$REPO_ROOT" && node -e '
  const D = require("better-sqlite3");
  const db = new D("data/v2.db");
  const rows = db.prepare("SELECT ag.folder, cc.mcp_servers FROM container_configs cc JOIN agent_groups ag ON ag.id = cc.agent_group_id").all();
  for (const r of rows) {
    const cd = JSON.parse(r.mcp_servers || "{}")["chrome-devtools"];
    if (!cd) continue;
    const url = ((cd.args) || []).find((a) => /^https?:\/\/[^/]*host\.docker\.internal:\d+/.test(a));
    if (url) console.log(r.folder);
  }
')"

if [[ -z "$LIVE_GROUPS" ]]; then
  echo "No live-browser groups found (none have a chrome-devtools MCP with a host bridge)."
  exit 0
fi

echo "Live-browser groups: $(echo "$LIVE_GROUPS" | tr '\n' ' ')"
echo

for GROUP in $LIVE_GROUPS; do
  LABEL="com.nanoclaw.live-chrome.$GROUP"
  PLIST="$LA_DIR/$LABEL.plist"
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$REPO_ROOT/scripts/live-chrome.sh</string>
        <string>$GROUP</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$REPO_ROOT</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$HOME</string>
        <key>PATH</key>
        <string>$PLIST_PATH</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$HOME/.nanoclaw-live-chrome/$GROUP-autostart.out.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.nanoclaw-live-chrome/$GROUP-autostart.err.log</string>
</dict>
</plist>
PLIST

  if plutil -lint "$PLIST" >/dev/null; then
    echo "  wrote $PLIST"
  else
    echo "  ERROR: invalid plist $PLIST" >&2
    exit 1
  fi

  if [[ "$START_NOW" == "1" ]]; then
    # If already loaded, restart it in place (kickstart -k) — avoids the
    # bootout->bootstrap teardown race that surfaces as "5: Input/output error".
    # If not loaded, clear the "disabled" flag (a disabled service ALSO fails
    # bootstrap with error 5) then bootstrap.
    if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
      launchctl kickstart -k "gui/$(id -u)/$LABEL" && echo "  restarted $LABEL"
    else
      launchctl enable "gui/$(id -u)/$LABEL" 2>/dev/null || true
      if launchctl bootstrap "gui/$(id -u)" "$PLIST"; then
        echo "  loaded + started $LABEL"
      else
        echo "  WARN: could not load $LABEL (try again, or: launchctl enable gui/$(id -u)/$LABEL)"
      fi
    fi
  fi
done

echo
if [[ "$START_NOW" == "1" ]]; then
  echo "Done. Live browsers are running now and will restart on every login."
else
  echo "Done. Plists written; they load automatically at next login/restart."
  echo "To launch them now without waiting, re-run with --start-now."
fi
