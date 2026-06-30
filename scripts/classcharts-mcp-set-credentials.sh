#!/usr/bin/env bash
#
# classcharts-mcp-set-credentials.sh — Store ClassCharts parent credentials in
# the OneCLI vault so the rs-assistant agent can authenticate to the ClassCharts
# MCP server at http://100.108.5.11:4181/mcp.
#
# The OneCLI gateway intercepts requests to 100.108.5.11 and injects
# "Authorization: Basic <base64(email:password)>" automatically (same mechanism
# as the Grub MCP server on the same host). Credentials never touch disk.
#
# Where to find the values:
#   ClassCharts portal → parent login → the email and password you use to log in.
#
# Usage:
#   bash scripts/classcharts-mcp-set-credentials.sh
#
set -euo pipefail

AGENT_GROUP_ID="ag-1782809385410-ql7ovb"
SECRET_NAME="ClassCharts MCP"
HOST_PATTERN="100.108.5.11"
PATH_PATTERN="/classcharts/mcp"

echo "ClassCharts MCP credentials setup"
echo "(used to authenticate to the ClassCharts MCP server over Tailscale)"
echo

read -r -p "ClassCharts parent email: " EMAIL
if [[ -z "$EMAIL" ]]; then echo "email cannot be empty" >&2; exit 1; fi

read -r -s -p "ClassCharts parent password (input hidden): " PASSWORD
echo
if [[ -z "$PASSWORD" ]]; then echo "password cannot be empty" >&2; exit 1; fi

# Encode as base64(email:password). Pass through env to keep it off the command line.
B64=$(EMAIL="$EMAIL" PASSWORD="$PASSWORD" python3 -c "
import base64, os
val = base64.b64encode((os.environ['EMAIL'] + ':' + os.environ['PASSWORD']).encode()).decode()
print(val)
")
unset PASSWORD

echo
echo "Storing secret in OneCLI vault..."

AGENT_ID=$(onecli agents list 2>&1 | python3 -c "
import sys, json
try:
    resp = json.load(sys.stdin)
    for a in (resp.get('data', resp) if isinstance(resp, dict) else resp):
        if a.get('identifier') == '$AGENT_GROUP_ID':
            print(a['id'])
            break
except Exception:
    pass
")

if [[ -z "$AGENT_ID" ]]; then
  echo "Could not find OneCLI agent for group $AGENT_GROUP_ID" >&2
  echo "Run 'onecli agents list' to verify the agent exists." >&2
  exit 1
fi

EXISTING_ID=$(onecli secrets list 2>&1 | python3 -c "
import sys, json
try:
    resp = json.load(sys.stdin)
    secrets = resp.get('data', resp) if isinstance(resp, dict) else resp
    for s in secrets:
        if s.get('name') == '$SECRET_NAME' and s.get('hostPattern') == '$HOST_PATTERN':
            print(s['id'])
            break
except Exception:
    pass
")

if [[ -n "$EXISTING_ID" ]]; then
  echo "  Updating existing vault secret..."
  onecli secrets update --id "$EXISTING_ID" --value "$B64" > /dev/null
else
  echo "  Creating new vault secret..."
  NEW_SECRET=$(onecli secrets create \
    --name "$SECRET_NAME" \
    --type generic \
    --value "$B64" \
    --host-pattern "$HOST_PATTERN" \
    --path-pattern "$PATH_PATTERN" \
    --header-name "Authorization" \
    --value-format "Basic {value}" 2>&1)
  EXISTING_ID=$(echo "$NEW_SECRET" | python3 -c "
import sys, json
try:
    resp = json.load(sys.stdin)
    obj = resp.get('data', resp) if isinstance(resp, dict) else {}
    print(obj.get('id', ''))
except Exception:
    pass
")
  if [[ -z "$EXISTING_ID" ]]; then
    echo "Secret creation failed: $NEW_SECRET" >&2
    exit 1
  fi
fi

unset B64

CURRENT_SECRETS=$(onecli agents secrets --id "$AGENT_ID" 2>&1 | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    ids = data.get('data', [])
    print(','.join(ids))
except Exception:
    pass
")

if echo "$CURRENT_SECRETS" | grep -q "$EXISTING_ID"; then
  echo "  Secret already assigned to rs-assistant."
else
  if [[ -n "$CURRENT_SECRETS" ]]; then
    NEW_SET="$CURRENT_SECRETS,$EXISTING_ID"
  else
    NEW_SET="$EXISTING_ID"
  fi
  onecli agents set-secrets --id "$AGENT_ID" --secret-ids "$NEW_SET" > /dev/null
  echo "  Assigned secret to rs-assistant."
fi

echo
echo "Done. Restart rs-assistant to apply:"
echo "  ncl groups restart --id $AGENT_GROUP_ID --message 'ClassCharts MCP auth fixed'"
