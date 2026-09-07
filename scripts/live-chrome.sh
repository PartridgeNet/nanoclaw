#!/usr/bin/env bash
#
# live-chrome.sh — Launch a dedicated live, headed Chromium that a NanoClaw
# agent group drives over CDP (via its `chrome-devtools` MCP server), for any
# site that needs a real, persistent, logged-in browser: sites with strong bot
# detection, or accounts where exported cookie sessions get rejected (e.g.
# Google — device-bound session checks reject transferred cookies, so a real
# headed browser you sign into is the only path that holds).
#
# One profile per group: an isolated, persistent Chromium profile that YOU sign
# into. The agent drives it through the host-side DevTools bridge
# (scripts/chrome-devtools-bridge.mjs). For plain anonymous browsing the agent
# still has its in-container `agent-browser`.
#
# Ports: the bridge port is read from the group's own chrome-devtools MCP config
# (`--browserUrl http://host.docker.internal:<port>`), so the launcher and the
# container always agree. Chromium's debug port defaults to <bridge_port - 1>.
# Override either with LIVE_BRIDGE_PORT / LIVE_CHROME_PORT.
#
# Logins persist in the profile, so you sign in once per site and rarely
# re-auth. Sign into as many sites as you like in the one window, and leave it
# running whenever you want the agent to browse as you.
#
# Usage:
#   bash scripts/live-chrome.sh <group> [start-url]
#   bash scripts/live-chrome.sh rs-work-pa https://linear.app
#
set -euo pipefail

GROUP="${1:?usage: live-chrome.sh <group> [start-url]}"
START_URL="${2:-}"   # defaulted to the group's titled home page below

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE="${LIVE_CHROME_PROFILE:-$HOME/.nanoclaw-live-chrome/$GROUP}"
CHROME="${LIVE_CHROME_BIN:-/usr/bin/chromium}"

if [[ ! -x "$CHROME" ]]; then
  echo "Chromium not found at: $CHROME. Set LIVE_CHROME_BIN to override." >&2
  exit 1
fi

# Auto-detect display if not already in the environment (common when launching
# from a systemd service or SSH session that doesn't inherit the desktop env).
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_RUNTIME_DIR
if [[ -z "${DISPLAY:-}" && -S "/tmp/.X11-unix/X0" ]]; then
  export DISPLAY=:0
fi
if [[ -z "${WAYLAND_DISPLAY:-}" && -S "$XDG_RUNTIME_DIR/wayland-1" ]]; then
  export WAYLAND_DISPLAY=wayland-1
fi
if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
  echo "No display found. Run from a graphical terminal, or set \$DISPLAY / \$WAYLAND_DISPLAY." >&2
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
if ss -tlnp "sport = :$BRIDGE_PORT" 2>/dev/null | grep -q LISTEN; then
  echo "Bridge already running on port $BRIDGE_PORT."
else
  echo "Starting Chrome DevTools bridge on port $BRIDGE_PORT (log: $BRIDGE_LOG)"
  BRIDGE_PORT="$BRIDGE_PORT" CHROME_PORT="$CHROME_PORT" \
    nohup node "$SCRIPT_DIR/chrome-devtools-bridge.mjs" >>"$BRIDGE_LOG" 2>&1 &
  disown || true
fi

# Name this group's profile so its window is identifiable — Chromium shows the
# name in the profile button/menu. Stored in <user-data-dir>/Local State under
# profile.info_cache.<dir>; we merge it (preserving all other keys) with
# Chromium stopped, so it applies on the next fresh launch.
LS_FILE="$PROFILE/Local State"
if [[ -f "$LS_FILE" ]]; then
  LIVE_CHROME_LABEL="$GROUP" node -e '
    const fs = require("fs");
    const group = process.env.LIVE_CHROME_LABEL;
    const lsPath = process.argv[1];
    let ls = {};
    try { ls = JSON.parse(fs.readFileSync(lsPath, "utf8")); } catch { process.exit(0); }
    ls.profile = ls.profile || {};
    const cache = (ls.profile.info_cache = ls.profile.info_cache || {});
    const dirs = Object.keys(cache).length ? Object.keys(cache) : ["Default"];
    for (const d of dirs) {
      const e = (cache[d] = cache[d] || {});
      e.name = group;
      e.is_using_default_name = false;
    }
    fs.writeFileSync(lsPath, JSON.stringify(ls));
  ' "$LS_FILE" || echo "  (profile naming skipped)"
fi

# Set Chromium's default download directory to the group workspace so downloaded
# files land somewhere the agent can read (mounted at /workspace/agent/downloads
# inside the container). Write to Default/Preferences before launch; Chromium
# honors user-preference keys written externally and rewrites the protection
# hash on exit, so this sticks across restarts without manual UI changes.
DOWNLOAD_DIR="$REPO_ROOT/groups/$GROUP/downloads"
mkdir -p "$DOWNLOAD_DIR"
PREFS_FILE="$PROFILE/Default/Preferences"
if [[ -f "$PREFS_FILE" ]]; then
  DOWNLOAD_DIR="$DOWNLOAD_DIR" node -e '
    const fs = require("fs");
    const dlDir = process.env.DOWNLOAD_DIR;
    const pPath = process.argv[1];
    let prefs = {};
    try { prefs = JSON.parse(fs.readFileSync(pPath, "utf8")); } catch {}
    prefs.download = prefs.download || {};
    if (prefs.download.default_directory !== dlDir) {
      prefs.download.default_directory = dlDir;
      prefs.download.directory_upgrade = true;
      prefs.download.prompt_for_download = false;
      fs.writeFileSync(pPath, JSON.stringify(prefs));
      process.stderr.write("  download dir -> " + dlDir + "\n");
    }
  ' "$PREFS_FILE" || echo "  (download dir update skipped)"
else
  mkdir -p "$PROFILE/Default"
  DOWNLOAD_DIR="$DOWNLOAD_DIR" node -e '
    const fs = require("fs");
    const dlDir = process.env.DOWNLOAD_DIR;
    const pPath = process.argv[1];
    const prefs = { download: { default_directory: dlDir, directory_upgrade: true, prompt_for_download: false } };
    fs.writeFileSync(pPath, JSON.stringify(prefs));
    process.stderr.write("  download dir -> " + dlDir + "\n");
  ' "$PREFS_FILE" || echo "  (download dir init skipped)"
fi

# Give an idle window the agent name in its title bar via a titled home page
# used as the default start URL — its <title> is "[<group>]".
HOME_HTML="$HOME/.nanoclaw-live-chrome/$GROUP-home.html"
mkdir -p "$(dirname "$HOME_HTML")"
cat > "$HOME_HTML" <<HTML
<!doctype html><html><head><meta charset="utf-8"><title>[$GROUP]</title></head>
<body style="font:14px sans-serif;color:#666;padding:2rem">
Live browser for <b>$GROUP</b>. This window is driven by the $GROUP agent.
</body></html>
HTML
[[ -z "$START_URL" ]] && START_URL="file://$HOME_HTML"

echo "Launching live Chromium for group: $GROUP"
echo "  profile:    $PROFILE"
echo "  downloads:  $DOWNLOAD_DIR  (-> /workspace/agent/downloads in container)"
echo "  debug port: $CHROME_PORT (loopback only)  ->  bridge $BRIDGE_PORT"
echo "  start URL:  $START_URL"
# Service mode uses Xvfb (virtual X11 display) rather than --headless=new.
# Headed Chromium on a virtual display binds --remote-debugging-port correctly
# (unlike Wayland windowed mode) and presents a non-headless browser fingerprint
# (unlike --headless=new, which Cloudflare detects). Profile/cookies are fully
# preserved. Xvfb is started per-group on a display derived from BRIDGE_PORT
# (e.g. 9229 → :29) and killed when Chromium exits.
#
# Set LIVE_CHROME_HEADLESS=1 for service mode (done by the systemd unit).
# Omit or set to 0 for the interactive login window.
LIVE_CHROME_HEADLESS="${LIVE_CHROME_HEADLESS:-0}"

if [[ "$LIVE_CHROME_HEADLESS" == "1" ]]; then
  if ! command -v Xvfb >/dev/null 2>&1; then
    echo "Xvfb not found. Install xorg-server-xvfb (sudo pacman -S xorg-server-xvfb)." >&2
    exit 1
  fi

  # Unique virtual display per group, derived from bridge port (9229 → :29).
  VDISPLAY_NUM="$((BRIDGE_PORT - 9200))"
  VDISPLAY=":${VDISPLAY_NUM}"

  echo
  echo "Running in service mode (Xvfb virtual display ${VDISPLAY})."
  echo "To sign in to sites use:  bash scripts/live-chrome-login.sh ${GROUP}"

  Xvfb "$VDISPLAY" -screen 0 1920x1080x24 -nolisten tcp &
  XVFB_PID=$!
  trap "kill $XVFB_PID 2>/dev/null || true" EXIT

  # Wait up to 3 s for Xvfb socket to appear.
  for _i in 1 2 3 4 5 6; do
    [[ -S "/tmp/.X11-unix/X${VDISPLAY_NUM}" ]] && break
    sleep 0.5
  done

  export DISPLAY="$VDISPLAY"
  unset WAYLAND_DISPLAY  # ensure Chromium uses X11, not Wayland

  "$CHROME" \
    --user-data-dir="$PROFILE" \
    --remote-debugging-port="$CHROME_PORT" \
    --remote-allow-origins='*' \
    --no-first-run \
    --no-default-browser-check \
    --ozone-platform=x11 \
    "$START_URL"
else
  echo
  echo "Running in headed (login) mode for group: $GROUP"
  echo "Sign into whatever sites you need (approve any 2FA)."
  echo "Logins persist in this profile."
  echo
  if [[ -z "${LIVE_CHROME_LOGIN:-}" ]]; then
    echo "  Tip: use  bash scripts/live-chrome-login.sh $GROUP  instead — it"
    echo "  stops/restarts the service around this login window automatically."
  fi

  OZONE_PLATFORM="${LIVE_OZONE_PLATFORM:-}"
  if [[ -z "$OZONE_PLATFORM" ]]; then
    [[ -n "${WAYLAND_DISPLAY:-}" ]] && OZONE_PLATFORM=wayland || OZONE_PLATFORM=x11
  fi

  exec "$CHROME" \
    --user-data-dir="$PROFILE" \
    --no-first-run \
    --no-default-browser-check \
    --ozone-platform="$OZONE_PLATFORM" \
    "$START_URL"
fi
