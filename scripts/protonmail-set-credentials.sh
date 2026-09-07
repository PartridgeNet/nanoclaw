#!/usr/bin/env bash
#
# protonmail-set-credentials.sh — Store Proton Mail Bridge credentials for an
# rs-assistant-style agent group, WITHOUT the password ever touching the chat
# transcript or the terminal scrollback.
#
# The bridge runs on this Mac and exposes IMAP/SMTP on loopback. The agent
# container reaches it via host.docker.internal. This script writes a gitignored
# credentials file into the group workspace that the `protonmail` skill reads.
#
# Where to find the values (Proton Mail Bridge app):
#   Settings -> (your account) -> "Mailbox configuration" / IMAP-SMTP details.
#   Username = your Proton email address.
#   Password = the BRIDGE-SPECIFIC password shown there (NOT your Proton login).
#
# Usage:
#   bash scripts/protonmail-set-credentials.sh                 # group: rs-assistant
#   bash scripts/protonmail-set-credentials.sh meal-planner    # another group folder
#
set -euo pipefail

GROUP="${1:-rs-assistant}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="$ROOT/groups/$GROUP/.protonmail"
DEST="$DEST_DIR/credentials.json"

if [[ ! -d "$ROOT/groups/$GROUP" ]]; then
  echo "Group folder not found: groups/$GROUP" >&2
  echo "Known groups:" >&2
  ls -1 "$ROOT/groups" 2>/dev/null | sed 's/^/  /' >&2
  exit 1
fi

echo "Setting Proton Mail Bridge credentials for group: $GROUP"
echo "(values come from the Proton Mail Bridge app — see this script's header)"
echo

read -r -p "Proton email (bridge username): " USERNAME
if [[ -z "$USERNAME" ]]; then echo "username cannot be empty" >&2; exit 1; fi

# -s: silent. The password is never printed, never stored in history.
read -r -s -p "Bridge password (input hidden): " PASSWORD
echo
if [[ -z "$PASSWORD" ]]; then echo "password cannot be empty" >&2; exit 1; fi

# Optional overrides; defaults match Proton Mail Bridge + Docker Desktop for Mac.
IMAP_HOST="${PROTON_IMAP_HOST:-host.docker.internal}"
IMAP_PORT="${PROTON_IMAP_PORT:-1143}"
SMTP_HOST="${PROTON_SMTP_HOST:-host.docker.internal}"
SMTP_PORT="${PROTON_SMTP_PORT:-1025}"

mkdir -p "$DEST_DIR"
umask 077
# Write via a small helper so the password is passed through the environment to
# one process and not interpolated into a logged command line.
USERNAME="$USERNAME" PASSWORD="$PASSWORD" \
IMAP_HOST="$IMAP_HOST" IMAP_PORT="$IMAP_PORT" \
SMTP_HOST="$SMTP_HOST" SMTP_PORT="$SMTP_PORT" \
python3 - "$DEST" <<'PY'
import json, os, sys
dest = sys.argv[1]
data = {
    "username": os.environ["USERNAME"],
    "password": os.environ["PASSWORD"],
    "imap_host": os.environ["IMAP_HOST"],
    "imap_port": int(os.environ["IMAP_PORT"]),
    "smtp_host": os.environ["SMTP_HOST"],
    "smtp_port": int(os.environ["SMTP_PORT"]),
}
with open(dest, "w") as f:
    json.dump(data, f, indent=2)
os.chmod(dest, 0o600)
PY

unset PASSWORD
echo
echo "Wrote $DEST (mode 600, gitignored under groups/*)."
echo "It's picked up live — no rebuild needed. Test from the host with:"
echo "  docker run --rm --entrypoint python3 \\"
echo "    -v \"$DEST\":/workspace/agent/.protonmail/credentials.json:ro \\"
echo "    nanoclaw-agent-v2-32406a8d:$( [[ "$GROUP" == "rs-assistant" ]] && echo ag-1782809385410-ql7ovb || echo latest ) \\"
echo "    /workspace/agent/skills/$GROUP/.../proton.py folders   # (adjust path)"
