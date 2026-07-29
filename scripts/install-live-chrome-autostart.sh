#!/usr/bin/env bash
#
# install-live-chrome-autostart.sh — Register a systemd user service per live
# agent browser so each group's dedicated Chromium comes back automatically
# when the host restarts.
#
# A "live browser" group is one whose container config has a chrome-devtools
# MCP server pointing at a host bridge (`--browserUrl http://host.docker.internal:<port>`).
# Groups whose chrome-devtools MCP has no browserUrl are skipped.
#
# Each service runs `scripts/live-chrome.sh <group>`, which also (idempotently)
# starts that group's host-side DevTools bridge. Service units land in
# ~/.config/systemd/user/ and are enabled for graphical-session.target.
#
# Usage:
#   bash scripts/install-live-chrome-autostart.sh              # write + enable units
#   bash scripts/install-live-chrome-autostart.sh --start-now  # also start them now
#
set -euo pipefail

START_NOW=0
[[ "${1:-}" == "--start-now" ]] && START_NOW=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"

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
  UNIT="nanoclaw-live-chrome-${GROUP}.service"
  UNIT_FILE="$UNIT_DIR/$UNIT"

  cat > "$UNIT_FILE" <<UNIT
[Unit]
Description=NanoClaw live browser for ${GROUP}
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
Environment=LIVE_CHROME_HEADLESS=1
ExecStart=/bin/bash ${REPO_ROOT}/scripts/live-chrome.sh ${GROUP}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
UNIT

  echo "  wrote $UNIT_FILE"
done

systemctl --user daemon-reload

for GROUP in $LIVE_GROUPS; do
  UNIT="nanoclaw-live-chrome-${GROUP}.service"
  systemctl --user enable "$UNIT"
  echo "  enabled $UNIT"

  if [[ "$START_NOW" == "1" ]]; then
    systemctl --user restart "$UNIT"
    echo "  started $UNIT"
  fi
done

echo
if [[ "$START_NOW" == "1" ]]; then
  echo "Done. Live browsers are running now and will restart on every graphical session start."
else
  echo "Done. Services enabled; they start automatically with your next graphical session."
  echo "To launch them now without waiting, re-run with --start-now."
fi
