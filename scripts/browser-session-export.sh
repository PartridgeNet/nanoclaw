#!/usr/bin/env bash
#
# browser-session-export.sh — Log in to a website on this Mac and export the
# session for the NanoClaw agent hosted on rob.s@assistant to use.
#
# This is the ergonomic, general version of the "session export" browser-auth
# approach: you log in once in a real Chrome or Brave window, and the resulting
# cookies + localStorage are copied over SSH/SCP into the hosted agent group's
# workspace as a Playwright storageState file. The agent's own headless browser
# (`agent-browser state load`) then reuses that session — auth stays scoped to
# just the sites you log into, and the token never enters chat or env.
#
# The session file lands at:
#   groups/<group>/.browser-sessions/<name>-exported-session.json   (mode 600, gitignored)
# which surfaces live inside the container at:
#   /workspace/agent/.browser-sessions/<name>-exported-session.json
# No rebuild or restart needed.
#
# CAVEAT: sites with strong bot detection (e.g. Tesco) block a fresh headless
# browser even with a valid session. Those need the live-browser approach
# (see scripts/tesco-chrome.sh), not session export.
#
# Usage:
#   bash scripts/browser-session-export.sh <group> [name] [login-url]
#   bash scripts/browser-session-export.sh personal-shopper amazon https://www.amazon.co.uk/
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROWSER_CMD=()
BROWSER_NAME=""
REMOTE_TARGET="rob.s@assistant"
REMOTE_ROOT="/Users/rob.s/src/PartridgeNet/nanoclaw"

shell_quote() {
  printf '%q' "$1"
}

remote_eval() {
  tailscale ssh "$REMOTE_TARGET" "bash -lc $(shell_quote "$1")"
}

ensure_remote_connection() {
  if ! remote_eval "printf 'ok\n'" >/dev/null; then
    echo "Could not connect to $REMOTE_TARGET with Tailscale SSH." >&2
    echo "Check that the assistant machine is online, reachable on Tailscale, and accepting SSH." >&2
    echo "Try: tailscale ping assistant" >&2
    echo "Then: tailscale ssh $REMOTE_TARGET 'pwd'" >&2
    exit 1
  fi
}

ensure_tailnet_connection() {
  local status_check
  if ! status_check="$(tailscale status --json 2>&1 | node -e '
let data = "";
process.stdin.on("data", (chunk) => { data += chunk; });
process.stdin.on("end", () => {
  try {
    const status = JSON.parse(data);
    const health = Array.isArray(status.Health) ? status.Health : [];
    const self = status.Self || {};

    if (status.BackendState !== "Running") {
      console.error(`Tailscale backend is ${status.BackendState || "unknown"}, not Running.`);
      process.exit(1);
    }
    if (!status.HaveNodeKey) {
      console.error("Tailscale is not logged in on this machine.");
      process.exit(1);
    }
    if (self.Online === false) {
      console.error("This machine is currently offline in Tailscale.");
      for (const message of health) console.error(`  - ${message}`);
      process.exit(1);
    }
  } catch (err) {
    console.error(`Could not parse tailscale status --json: ${err.message}`);
    process.exit(1);
  }
});
')" ; then
    echo "$status_check" >&2
    echo "Bring this machine online in Tailscale, then rerun this script." >&2
    echo "Try: tailscale status --self --peers=false" >&2
    echo "Then reconnect with the Tailscale app or run: tailscale up" >&2
    exit 1
  fi
}

remote_list_groups() {
  remote_eval "if [ -d $(shell_quote "$REMOTE_ROOT/groups") ]; then ls -1 $(shell_quote "$REMOTE_ROOT/groups") 2>/dev/null | sed 's/^/  /'; fi"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

use_browser_path() {
  BROWSER_CMD=("$2")
  BROWSER_NAME="$1"
}

try_browser_path() {
  local name="$1"
  local path="$2"
  if [[ -x "$path" ]]; then
    use_browser_path "$name" "$path"
    return 0
  fi
  return 1
}

try_browser_command() {
  local name="$1"
  local command_name="$2"
  local resolved
  if resolved="$(command -v "$command_name" 2>/dev/null)" && [[ -n "$resolved" ]]; then
    use_browser_path "$name" "$resolved"
    return 0
  fi
  return 1
}

select_browser() {
  if [[ -n "${BROWSER_EXPORT_BROWSER:-}" ]]; then
    if [[ -x "$BROWSER_EXPORT_BROWSER" ]]; then
      use_browser_path "${BROWSER_EXPORT_BROWSER_NAME:-Custom browser}" "$BROWSER_EXPORT_BROWSER"
      return
    fi
    echo "BROWSER_EXPORT_BROWSER is not executable: $BROWSER_EXPORT_BROWSER" >&2
    exit 1
  fi

  local home_apps="${HOME:-}/Applications"

  if try_browser_path "Google Chrome" "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ||
    try_browser_path "Google Chrome" "$home_apps/Google Chrome.app/Contents/MacOS/Google Chrome" ||
    try_browser_command "Google Chrome" google-chrome-stable ||
    try_browser_command "Google Chrome" google-chrome ||
    try_browser_command "Google Chrome" chrome; then
    return
  fi

  if try_browser_path "Brave Browser" "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" ||
    try_browser_path "Brave Browser" "$home_apps/Brave Browser.app/Contents/MacOS/Brave Browser" ||
    try_browser_path "Brave Browser Beta" "/Applications/Brave Browser Beta.app/Contents/MacOS/Brave Browser Beta" ||
    try_browser_path "Brave Browser Beta" "$home_apps/Brave Browser Beta.app/Contents/MacOS/Brave Browser Beta" ||
    try_browser_path "Brave Browser Nightly" "/Applications/Brave Browser Nightly.app/Contents/MacOS/Brave Browser Nightly" ||
    try_browser_path "Brave Browser Nightly" "$home_apps/Brave Browser Nightly.app/Contents/MacOS/Brave Browser Nightly" ||
    try_browser_path "Brave Browser" "/opt/brave.com/brave/brave-browser" ||
    try_browser_command "Brave Browser" brave-browser ||
    try_browser_command "Brave Browser" brave-browser-stable ||
    try_browser_command "Brave Browser" brave ||
    try_browser_command "Brave Browser Nightly" brave-nightly ||
    try_browser_path "Brave Browser" "/snap/bin/brave"; then
    return
  fi

  if command -v flatpak >/dev/null 2>&1 && flatpak info com.brave.Browser >/dev/null 2>&1; then
    BROWSER_CMD=(flatpak run com.brave.Browser)
    BROWSER_NAME="Brave Browser (Flatpak)"
    return
  fi

  echo "Neither Google Chrome nor Brave Browser was found." >&2
  echo "Checked:" >&2
  echo "  /Applications/Google Chrome.app/Contents/MacOS/Google Chrome" >&2
  echo "  $home_apps/Google Chrome.app/Contents/MacOS/Google Chrome" >&2
  echo "  google-chrome-stable, google-chrome, chrome on PATH" >&2
  echo "  /Applications/Brave Browser.app/Contents/MacOS/Brave Browser" >&2
  echo "  $home_apps/Brave Browser.app/Contents/MacOS/Brave Browser" >&2
  echo "  /opt/brave.com/brave/brave-browser, /snap/bin/brave" >&2
  echo "  brave-browser, brave-browser-stable, brave, brave-nightly on PATH" >&2
  echo "  Flatpak app com.brave.Browser" >&2
  echo "Set BROWSER_EXPORT_BROWSER=/path/to/browser if it is installed elsewhere." >&2
  exit 1
}

GROUP="${1:-}"
if [[ -z "$GROUP" ]]; then
  echo "Usage: bash scripts/browser-session-export.sh <group> [name] [login-url]" >&2
  exit 1
fi
require_cmd curl
require_cmd node
require_cmd scp
require_cmd tailscale

NAME="${2:-}"
if [[ -z "$NAME" ]]; then
  read -r -p "Short name for this session (e.g. amazon, linkedin): " NAME
fi
# Normalise the name to a safe slug.
NAME="$(echo "$NAME" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9._-')"
if [[ -z "$NAME" ]]; then echo "name cannot be empty" >&2; exit 1; fi

LOGIN_URL="${3:-}"
if [[ -z "$LOGIN_URL" ]]; then
  read -r -p "Login URL to open: " LOGIN_URL
fi
if [[ -z "$LOGIN_URL" ]]; then echo "login URL cannot be empty" >&2; exit 1; fi

if [[ ! -d "$SCRIPT_DIR" || ! -f "$SCRIPT_DIR/browser-session-export.mjs" ]]; then
  echo "Local capture helper not found: $SCRIPT_DIR/browser-session-export.mjs" >&2
  exit 1
fi
select_browser

REMOTE_GROUP_DIR="$REMOTE_ROOT/groups/$GROUP"
echo "Checking NanoClaw host at $REMOTE_TARGET..."
ensure_tailnet_connection
ensure_remote_connection
if ! remote_eval "test -d $(shell_quote "$REMOTE_ROOT")"; then
  echo "Remote NanoClaw checkout not found: $REMOTE_TARGET:$REMOTE_ROOT" >&2
  exit 1
fi
if ! remote_eval "test -f $(shell_quote "$REMOTE_ROOT/scripts/browser-session-scaffold.mjs")"; then
  echo "Remote scaffold script not found: $REMOTE_TARGET:$REMOTE_ROOT/scripts/browser-session-scaffold.mjs" >&2
  exit 1
fi
if ! remote_eval "test -d $(shell_quote "$REMOTE_GROUP_DIR")"; then
  echo "Group folder not found on $REMOTE_TARGET: groups/$GROUP" >&2
  echo "Known groups on $REMOTE_TARGET:" >&2
  remote_list_groups >&2 || true
  exit 1
fi

REMOTE_DEST_DIR="$REMOTE_GROUP_DIR/.browser-sessions"
REMOTE_DEST="$REMOTE_DEST_DIR/$NAME-exported-session.json"
REMOTE_MANIFEST="$REMOTE_DEST_DIR/index.json"
REMOTE_SKILL_DIR="$REMOTE_GROUP_DIR/skills/browser-session"
REMOTE_UPLOAD="/tmp/nanoclaw-browser-session-$NAME-$$.json"
REMOTE_TMP="$REMOTE_DEST_DIR/.$NAME-exported-session.$$.tmp"
DEBUG_PORT="${BROWSER_EXPORT_PORT:-9333}"
# Throwaway profile so ONLY this site's session is captured (auth stays scoped).
PROFILE="$(mktemp -d "${TMPDIR:-/tmp}/nanoclaw-export-$NAME.XXXXXX")"
LOCAL_STATE="$(mktemp "${TMPDIR:-/tmp}/nanoclaw-export-$NAME-state.XXXXXX.json")"
REMOTE_CLEANUP_NEEDED=0

cleanup() {
  [[ -n "${BROWSER_PID:-}" ]] && kill "$BROWSER_PID" >/dev/null 2>&1 || true
  rm -rf "$PROFILE" >/dev/null 2>&1 || true
  rm -f "$LOCAL_STATE" >/dev/null 2>&1 || true
  if [[ "$REMOTE_CLEANUP_NEEDED" == "1" ]]; then
    remote_eval "rm -f $(shell_quote "$REMOTE_UPLOAD") $(shell_quote "$REMOTE_TMP")" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo
echo "Exporting a browser session"
echo "  host:       $REMOTE_TARGET"
echo "  group:      $GROUP"
echo "  name:       $NAME"
echo "  login URL:  $LOGIN_URL"
echo "  browser:    $BROWSER_NAME"
echo "  ->          $REMOTE_TARGET:$REMOTE_DEST"
echo
echo "A dedicated $BROWSER_NAME window will open. Log in fully (username, password, any"
echo "MFA / 'remember me'). Leave the site on a logged-in page, then come back"
echo "here and press Enter to capture the session."
echo

"${BROWSER_CMD[@]}" \
  --user-data-dir="$PROFILE" \
  --remote-debugging-port="$DEBUG_PORT" \
  --remote-allow-origins='*' \
  --no-first-run \
  --no-default-browser-check \
  "$LOGIN_URL" >/dev/null 2>&1 &
BROWSER_PID=$!

# Wait for the DevTools endpoint to come up.
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$DEBUG_PORT/json/version" >/dev/null 2>&1; then break; fi
  sleep 0.5
done

read -r -p "Press Enter once you're logged in... " _

echo "Capturing session..."
node "$SCRIPT_DIR/browser-session-export.mjs" --port "$DEBUG_PORT" --out "$LOCAL_STATE"

echo "Uploading session to $REMOTE_TARGET..."
remote_eval "mkdir -p $(shell_quote "$REMOTE_DEST_DIR")"
REMOTE_CLEANUP_NEEDED=1
scp "$LOCAL_STATE" "$REMOTE_TARGET:$REMOTE_UPLOAD"
remote_eval "chmod 600 $(shell_quote "$REMOTE_UPLOAD") && mv $(shell_quote "$REMOTE_UPLOAD") $(shell_quote "$REMOTE_TMP") && chmod 600 $(shell_quote "$REMOTE_TMP") && mv $(shell_quote "$REMOTE_TMP") $(shell_quote "$REMOTE_DEST")"

# Refresh the per-group skill + manifest so the agent knows this session exists.
echo "Updating remote browser-session manifest and skill..."
remote_eval "GROUP=$(shell_quote "$GROUP") NAME=$(shell_quote "$NAME") LOGIN_URL=$(shell_quote "$LOGIN_URL") DEST=$(shell_quote "$REMOTE_DEST") MANIFEST=$(shell_quote "$REMOTE_MANIFEST") SKILL_DIR=$(shell_quote "$REMOTE_SKILL_DIR") node $(shell_quote "$REMOTE_ROOT/scripts/browser-session-scaffold.mjs")"
REMOTE_CLEANUP_NEEDED=0

echo
echo "Done. Session saved on $REMOTE_TARGET (mode 600, gitignored) and available to $GROUP live."
echo "The agent loads it with:"
echo "  agent-browser state load /workspace/agent/.browser-sessions/$NAME-exported-session.json"
echo
echo "Re-run this script whenever the session expires (agent lands on a login page)."
