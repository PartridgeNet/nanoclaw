# Remote OneCLI gateway (PartridgeNet: nipogi-e3)

PartridgeNet-specific deployment note. This install does **not** run the OneCLI
gateway on the Mac that runs NanoClaw. The gateway lives on a separate machine
(`nipogi-e3`) and is reached over Tailscale, so that AI agents on the Mac **and
on other machines** can share one credential vault. This document records what
was set up, why, and the one item still unverified, so future turns don't
re-derive it (or "fix" deliberate choices).

> Default OneCLI background — secret modes, the credential-injection proxy, the
> host-side approval bridge — lives in the root `CLAUDE.md` ("Secrets /
> Credentials / OneCLI"). This doc only covers the remote-hosting specifics.

## Goal / why remote

A single shared OneCLI vault, hosted off the Mac, reachable by NanoClaw (and
other agent tooling) running on multiple machines across the tailnet. The
tailnet is treated as the trust boundary.

## Topology

| Thing | Value |
|-------|-------|
| Gateway host | `nipogi-e3` (Linux, Docker), tailnet owner `thisdotrob@` |
| Tailscale IP | `100.71.226.93` |
| SSH | Tailscale SSH as user **`rs`** (`ssh rs@nipogi-e3`) |
| Install | `curl -fsSL https://onecli.sh/install \| sh` → docker compose project `onecli` at `/home/rs/.onecli/` |
| Image | `ghcr.io/onecli/onecli:latest` (currently **1.39.0**) |
| API / dashboard | `http://100.71.226.93:10254` |
| Gateway proxy (HTTPS_PROXY target) | `http://100.71.226.93:10255` |
| Postgres | `postgres:18-alpine`, reachable only on `127.0.0.1:5432` of the host |
| Mac (NanoClaw host) | `robert-stevensons-mac`, tailscale IP `100.88.69.113` |

**Version drift:** NanoClaw pins gateway `1.36.0` (`setup/onecli.ts`/`versions.json`);
this remote runs `1.39.0`. Same v1 API line, health/compat probe passes. Be
aware they differ.

## Changes made on nipogi-e3

The installer auto-bound the gateway to the Docker bridge IP (`172.17.0.1`),
which is only reachable from nipogi-e3 itself. Two edits made it reachable over
the tailnet without exposing more than necessary.

### 1. Bind host → Tailscale IP

The compose file is parameterised by `${ONECLI_BIND_HOST:-127.0.0.1}`; the
installer passed `172.17.0.1` inline at `up` time and persisted nothing. We
created the (previously absent) compose-dir env file:

```
# /home/rs/.onecli/.env
ONECLI_BIND_HOST=100.71.226.93
```

This binds the `onecli` service's `10254`/`10255` to the Tailscale IP and also
feeds `APP_URL` / `GATEWAY_API_URL` (→ `http://100.71.226.93:1025x`).

### 2. Postgres pinned to loopback

`ONECLI_BIND_HOST` otherwise controls the postgres port too. To keep the DB off
the tailnet, the postgres `ports` line in `docker-compose.yml` was hardcoded:

```yaml
      - "127.0.0.1:${POSTGRES_PORT:-5432}:5432"
```

(The gateway reaches postgres over the internal compose network, so it never
needs a tailnet-exposed host port.) Original compose backed up at
`/home/rs/.onecli/docker-compose.yml.bak`.

Re-up: `cd /home/rs/.onecli && docker compose -p onecli up -d`.

### 3. Firewall (ufw) — the FORWARD rule is the non-obvious bit

`nipogi-e3` runs ufw, default **deny incoming AND deny routed**. Tailscale SSH
bypasses ufw (handled in-process by tailscaled — which is why SSH worked while
the gateway ports were dropped). Docker published ports are reached via DNAT and
traverse the **FORWARD** chain, not INPUT, so an `allow in` rule is not enough.
The rule that actually unblocked it:

```bash
sudo ufw route allow in on tailscale0   # FORWARD — required for tailnet → container
```

Current ruleset (intentionally trusts the whole tailnet, see below):

```
10254,10255/tcp on tailscale0  ALLOW IN   Anywhere       # onecli gateway   (INPUT)
Anywhere on tailscale0         ALLOW IN   Anywhere       # trust tailnet    (INPUT)
Anywhere                       ALLOW FWD  Anywhere on tailscale0            (FORWARD)
```

DNAT in effect: `-d 100.71.226.93 --dport 10254 -j DNAT --to 172.18.0.3:10254`
(the gateway container on the compose bridge network). The `ufw-user-forward`
jump sits first in `DOCKER-USER`, ahead of the `ufw-docker` subnet-deny rules,
so it wins.

## Auth model — open by design, deliberately left open

The gateway runs in **`AUTH_MODE=local`** (confirmed via
`/app/data/runtime-config.json` → `{"authMode":"local","oauthConfigured":false}`),
chosen by the entrypoint because `NEXTAUTH_SECRET` is empty:

```sh
elif [ -n "$NEXTAUTH_SECRET" ]; then AUTH_MODE="oauth"; else AUTH_MODE="local"; fi
```

In `local` mode the gateway enforces **no API-key auth**: `/v1/agents`,
`/v1/secrets`, `/api/secrets` etc. all answer `200` with no `Authorization`
header. The "personal API key" shown in the dashboard exists but is **not
required**. The NanoClaw SDK only sends `Authorization: Bearer` when an apiKey
is set (`node_modules/@onecli-sh/sdk/lib/index.js` `buildHeaders`), so a blank
token Just Works here.

**This is intentional for this install.** The whole point is a vault shared by
agents on multiple tailnet machines; the tailnet is the trust boundary, so the
ufw rule trusts the entire tailscale interface rather than a single host.
Trade-off accepted: any tailnet node can read/use the vault unauthenticated.

There is **no lightweight "require the API key" switch** in this image. The only
ways to enforce auth are `oauth` mode (requires setting `NEXTAUTH_SECRET` **and**
an OAuth provider like `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET` — setting the
secret alone yields `oauth` mode with no working login and locks you out of the
dashboard) or the hosted `cloud` edition. The `api-key` string seen in the
bundle is unrelated — it is Codex credential metadata, not a gateway auth mode.

## NanoClaw (Mac) wiring

Set during `/setup` (Advanced → override OneCLI settings), or non-interactively
via `NANOCLAW_ONECLI_API_HOST` / `NANOCLAW_ONECLI_API_TOKEN`:

| `.env` key | Value |
|------------|-------|
| `ONECLI_URL` | `http://100.71.226.93:10254` (the **API** port, not `:10255`) |
| `ONECLI_API_KEY` | *(unset — not required in `local` mode; set it if auth is ever enforced)* |

- Setup health-polls `ONECLI_URL` (`/v1/health`) — does **not** validate the
  token. With a reachable URL it reports success even tokenless.
- NanoClaw **auto-creates one agent per agent-group** via `ensureAgent`
  (`src/container-runner.ts`); no manual `onecli agents create` needed.
  Auto-created agents default to `secretMode: all`, so vault secrets whose host
  pattern matches are injected automatically.
- **Egress lockdown must stay OFF** (`NANOCLAW_EGRESS_LOCKDOWN` unset/false). It
  is fundamentally incompatible with a remote gateway: it `docker network
  connect`s a *local* gateway container onto an internal network (see
  `src/egress-lockdown.ts`).

## Verified vs. open

**Verified** — Mac host → gateway over Tailscale:
```
:10254 /v1/health        → 200 {"status":"ok","version":"1.39.0"}
:10255 proxy → anthropic → 404 (proxy forwarded; expected reachable response)
```

**OPEN / UNVERIFIED — container reachability ("Part D").** The checks above ran
from the Mac *host*, not from inside a Docker agent container. Docker Desktop's
Linux VM does not always route to the host's Tailscale interface. Confirm with:

```bash
docker run --rm --add-host=host.docker.internal:host-gateway \
  --entrypoint curl nanoclaw-agent:latest \
  -s4 --connect-timeout 5 -o /dev/null -w "%{http_code}\n" \
  -x http://100.71.226.93:10255 https://api.anthropic.com
```

A response (e.g. `404`) = good. Timeout = the container can't reach the tailnet;
fall back to `tailscale serve --tcp` on nipogi-e3 or a local forwarder on the
Mac that containers reach via `host.docker.internal`. Container traffic NATs out
with the Mac's tailscale source IP (`100.88.69.113`), which matters if the ufw
rule is ever narrowed from "whole tailnet" to a per-host allowlist.

## Adding another machine to the shared vault

1. Join it to the tailnet.
2. Because ufw currently trusts the whole `tailscale0` interface, no firewall
   change is needed. (If the rule is ever scoped per-host, add that machine's
   tailscale IP to a `ufw route allow in on tailscale0 from <ip> to any port
   10254,10255 proto tcp`.)
3. Point its OneCLI client / NanoClaw at `http://100.71.226.93:10254`
   (`ONECLI_URL`), token unnecessary in `local` mode.
4. Run that machine's own container-reachability check (Part D) — it's
   per-machine.
