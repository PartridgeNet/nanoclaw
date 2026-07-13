#!/usr/bin/env bash
#
# browser-session-export.sh — Log in to a website on this Mac and export the
# session for a NanoClaw agent to use.
#
# This is the ergonomic, general version of the "session export" browser-auth
# approach: you log in once in a real Chrome window, and the resulting cookies +
# localStorage are written into the agent group's workspace as a Playwright
# storageState file. The agent's own headless browser (`agent-browser state
# load`) then reuses that session — auth stays scoped to just the sites you log
# into, and the token never enters chat or env.
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
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

GROUP="${1:-}"
if [[ -z "$GROUP" ]]; then
  echo "Usage: bash scripts/browser-session-export.sh <group> [name] [login-url]" >&2
  echo "Known groups:" >&2
  ls -1 "$ROOT/groups" 2>/dev/null | sed 's/^/  /' >&2
  exit 1
fi
if [[ ! -d "$ROOT/groups/$GROUP" ]]; then
  echo "Group folder not found: groups/$GROUP" >&2
  echo "Known groups:" >&2
  ls -1 "$ROOT/groups" 2>/dev/null | sed 's/^/  /' >&2
  exit 1
fi
if [[ ! -x "$CHROME" ]]; then
  echo "Google Chrome not found at: $CHROME" >&2
  exit 1
fi

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

DEST_DIR="$ROOT/groups/$GROUP/.browser-sessions"
DEST="$DEST_DIR/$NAME-exported-session.json"
DEBUG_PORT="${BROWSER_EXPORT_PORT:-9333}"
# Throwaway profile so ONLY this site's session is captured (auth stays scoped).
PROFILE="$(mktemp -d "${TMPDIR:-/tmp}/nanoclaw-export-$NAME.XXXXXX")"

cleanup() {
  [[ -n "${CHROME_PID:-}" ]] && kill "$CHROME_PID" >/dev/null 2>&1 || true
  rm -rf "$PROFILE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$DEST_DIR"

echo
echo "Exporting a browser session"
echo "  group:      $GROUP"
echo "  name:       $NAME"
echo "  login URL:  $LOGIN_URL"
echo "  ->          $DEST"
echo
echo "A dedicated Chrome window will open. Log in fully (username, password, any"
echo "MFA / 'remember me'). Leave the site on a logged-in page, then come back"
echo "here and press Enter to capture the session."
echo

"$CHROME" \
  --user-data-dir="$PROFILE" \
  --remote-debugging-port="$DEBUG_PORT" \
  --remote-allow-origins='*' \
  --no-first-run \
  --no-default-browser-check \
  "$LOGIN_URL" >/dev/null 2>&1 &
CHROME_PID=$!

# Wait for the DevTools endpoint to come up.
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$DEBUG_PORT/json/version" >/dev/null 2>&1; then break; fi
  sleep 0.5
done

read -r -p "Press Enter once you're logged in... " _

echo "Capturing session..."
node "$SCRIPT_DIR/browser-session-export.mjs" --port "$DEBUG_PORT" --out "$DEST"

# Refresh the per-group skill + manifest so the agent knows this session exists.
SKILL_DIR="$ROOT/groups/$GROUP/skills/browser-session"
mkdir -p "$SKILL_DIR"
MANIFEST="$DEST_DIR/index.json"
GROUP="$GROUP" NAME="$NAME" LOGIN_URL="$LOGIN_URL" DEST="$DEST" \
  MANIFEST="$MANIFEST" SKILL_DIR="$SKILL_DIR" \
  node "$SCRIPT_DIR/browser-session-scaffold.mjs"

echo
echo "Done. Session saved (mode 600, gitignored) and available to $GROUP live."
echo "The agent loads it with:"
echo "  agent-browser state load /workspace/agent/.browser-sessions/$NAME-exported-session.json"
echo
echo "Re-run this script whenever the session expires (agent lands on a login page)."
