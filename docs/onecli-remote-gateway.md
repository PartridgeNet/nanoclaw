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

### 4. Enable Docker at boot

Docker on nipogi-e3 is socket-activated (`docker.service` is `disabled`; it starts on first socket use). This means containers with a restart policy do **not** come back after a reboot — Docker only starts when something first pings its socket, which never happens automatically.

```bash
sudo systemctl enable docker
```

Without this, a reboot silently takes down the gateway until something manually triggers Docker. The compose restart policy handles container crashes fine; this covers host reboots.

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

## The egress-proxy-host bug (the `407` failure)

**Symptom.** Agents reply in chat with
`Error: ... Proxy connection failed: HTTP CONNECT failed with status 407`. The
host log is clean — messages route and deliver; the failure is *inside the
container*, on its way to Anthropic.

**Root cause.** NanoClaw's *API* calls (`ensureAgent`, container-config) go to
the remote gateway correctly (`ONECLI_URL`). But the container-config the
gateway returns bakes the **egress proxy** host into `HTTPS_PROXY` as
`host.docker.internal:10255` — OneCLI assumes the gateway is co-located with the
agent container. The gateway builds it as:

```js
// onecli image, apps/web .../api app route
let proxyUrl = `http://x:${accessToken}@${eu}`;
//  eu = process.env.GATEWAY_BASE_URL ?? "host.docker.internal:10255"
```

On Docker Desktop, `host.docker.internal` always resolves to **this** Mac (it is
injected by the Docker VM resolver — `--add-host` does **not** override it;
`getent hosts host.docker.internal` still returns `fdc4:f303:9324::254`). So the
agent's proxied calls hit a *local* gateway still running on the Mac (`onecli`
1.36.0 on `127.0.0.1:10254-10255`), which rejects the **remote-minted** token →
`407`. The remote token authenticates fine against the *remote* gateway — proven
by pointing a container's proxy straight at `100.71.226.93:10255` with the token
and getting a real `405` back from `api.anthropic.com` through the proxy.

### The fix — `GATEWAY_BASE_URL` on the gateway (server-side)

`GATEWAY_BASE_URL` (a bare `host:port`, no scheme — the gateway prepends
`http://x:<token>@`) is the sanctioned knob. It must be passed **into the
container**, which means it goes in the compose `env_file`, **not** the
substitution `.env`.

⚠️ **Two different `.env` files — easy to get wrong:**

| File | Mechanism | Used for |
|------|-----------|----------|
| `/home/rs/.onecli/.env` | Compose **variable substitution** (`${ONECLI_BIND_HOST}`) | `ONECLI_BIND_HOST` (binds ports). **Does NOT reach the container.** |
| `/home/rs/.env` | Compose **`env_file:`** (`env_file: - path: ../.env`) → injected as container env | `GATEWAY_BASE_URL` and anything the gateway app reads via `process.env` |

`GATEWAY_BASE_URL` is read by the app at runtime (`process.env.GATEWAY_BASE_URL`),
so it belongs in the `env_file` target. Putting it in `.onecli/.env` is inert —
it's never passed in (the symptom: `docker exec onecli printenv GATEWAY_BASE_URL`
is empty and the `407` persists). Bonus: `/home/rs/.env` sits *outside* `.onecli/`
and is `required: false`, so it survives a gateway reinstall.

```
# /home/rs/.env   (the env_file target — NOT .onecli/.env)
GATEWAY_BASE_URL=100.71.226.93:10255
```
```bash
cd /home/rs/.onecli && docker compose -p onecli up -d --force-recreate onecli
docker exec onecli printenv GATEWAY_BASE_URL    # must echo 100.71.226.93:10255
```

Correct for *all* tailnet consumers — they all reach the gateway at that IP.
Verify the config now returns the tailnet IP:

```bash
curl -s "http://100.71.226.93:10254/v1/container-config?agent=<agent-group-id>" \
  | grep -o '"HTTPS_PROXY":"[^"]*"'
# want: ...@100.71.226.93:10255  (not host.docker.internal)
```

This is the **single, intentional** fix for this install. NanoClaw is left
unmodified — no host-side proxy rewrite. (A host-side rewrite of the injected
proxy `-e` vars in `src/container-runner.ts` was prototyped and verified, then
reverted: it would have masked a misconfigured gateway and only helped NanoClaw,
not other tailnet consumers of the same vault. Keep the fix where every consumer
benefits — on the gateway.)

**Caveat — `GATEWAY_BASE_URL` is empty by default.** A wiped `/home/rs/.env` or
a fresh install will revert to `host.docker.internal:10255` and the `407`
returns. Re-set it after any such change; the verify command above is the canary.

## Verified

Mac host → gateway over Tailscale:
```
:10254 /v1/health        → 200 {"status":"ok","version":"1.39.0"}
:10255 proxy → anthropic → 404 (proxy forwarded; expected reachable response)
```

Container ("Part D") → gateway over Tailscale — **verified** (was open). From
inside the agent image, pointed straight at the tailnet IP with the agent token:
```bash
docker run --rm --entrypoint curl <agent-image> \
  -s4k --connect-timeout 8 -o /dev/null -w "%{http_code}\n" \
  -x "http://x:<token>@100.71.226.93:10255" https://api.anthropic.com/v1/messages
# → 405  (real Anthropic response through the proxy; CONNECT authed, creds injected)
```

A response (e.g. `404`/`405`) = good. Timeout = the container can't reach the
tailnet; fall back to `tailscale serve --tcp` on nipogi-e3 or a local forwarder
on the Mac. Container traffic NATs out with the Mac's tailscale source IP
(`100.88.69.113`), which matters if the ufw rule is ever narrowed from "whole
tailnet" to a per-host allowlist.

## Adding another machine to the shared vault

1. Join it to the tailnet.
2. Because ufw currently trusts the whole `tailscale0` interface, no firewall
   change is needed. (If the rule is ever scoped per-host, add that machine's
   tailscale IP to a `ufw route allow in on tailscale0 from <ip> to any port
   10254,10255 proto tcp`.)
3. Point its OneCLI client / NanoClaw at `http://100.71.226.93:10254`
   (`ONECLI_URL`), token unnecessary in `local` mode.
4. Run that machine's own container-reachability check (Part D, above) — it's
   per-machine.
5. No per-machine proxy config: with `GATEWAY_BASE_URL` set on the gateway, the
   new machine gets the correct egress proxy URL automatically (see "The
   egress-proxy-host bug" above).

## OAuth app connections need HTTPS (Trello, Google, GitHub, …)

Connecting a third-party **app** in the dashboard (`/connections` → an OAuth
provider like Trello) does **not** work when you browse the gateway over plain
HTTP on a raw IP/short-host. Symptom for Trello: the connect popup fails with
*"Connection failed — Missing state parameter"*, or Trello itself rejects it with
*"Invalid return_url. The return URL should match the application's allowed
origins."* Set up 2026-06-30; this section is the fix and the why.

### Why plain HTTP breaks it

- **The callback URL follows the *browsed host*, not `APP_URL`.** The gateway
  runs with `AUTH_TRUST_HOST=true` and derives the OAuth `return_url` from the
  incoming request's Host/`X-Forwarded-*` headers. So browsing
  `http://nipogi-e3:10254` produces `return_url=http://nipogi-e3:10254/v1/apps/<provider>/callback`.
  **Editing `APP_URL` does *not* change this** (verified: changed `APP_URL` to the
  HTTPS host, callback still echoed the browsed host). The browsed origin is what
  matters.
- **Trello (and most providers) require an HTTPS origin.** Trello's "Allowed
  Origins" rejects non-HTTPS, non-localhost origins, so an `http://<host>:10254`
  return_url is refused outright.
- **The OAuth `state` cookie is `Secure`.** Browsers silently drop `Secure`
  cookies set over `http://`, so even when a provider returns, the callback can't
  match state → "Missing state parameter." (Trello specifically uses
  `callback_method=fragment`/`response_type=token` and never round-trips `state`
  through the provider, so the cookie is the only state channel — doubly fragile
  over HTTP.)

Net: you must browse the dashboard over **HTTPS with a hostname**, and register
that exact HTTPS origin in the provider.

### The fix — front the gateway with `tailscale serve` (HTTPS, tailnet-only)

Run on **nipogi-e3** (needs root for cert + serve; or `sudo tailscale set --operator=$USER` once):

```bash
sudo tailscale cert nipogi-e3.tail8ea293.ts.net     # provisions the Let's Encrypt cert
                                                     # (requires MagicDNS + HTTPS Certs enabled tailnet-wide)
sudo tailscale serve --bg http://100.71.226.93:10254 # https://nipogi-e3.tail8ea293.ts.net (:443) → gateway :10254
tailscale serve status                               # shows "/ proxy http://100.71.226.93:10254", "tailnet only"
```

- ⚠️ **Newer Tailscale CLI syntax.** `tailscale serve --bg https / <target>` is
  rejected ("the CLI for serve and funnel has changed"); use
  `tailscale serve --bg http://100.71.226.93:10254` (it mounts at `/` on `:443`).
- ⚠️ **`tailscale serve` proxies to the gateway's *bound* address**, which is the
  tailnet IP (`100.71.226.93:10254`), **not** `127.0.0.1` (the gateway binds
  `ONECLI_BIND_HOST`, not loopback). Targeting `127.0.0.1:10254` would fail.
- ✅ **`serve` is tailnet-only — NOT public.** Public exposure is `tailscale
  funnel`, which we did **not** run. Verify with `tailscale funnel status` →
  "No funnel config".

### `APP_URL` was changed too (kept, though it's not the callback knob)

During debugging `APP_URL` was pointed at the HTTPS host. It turned out **not** to
be what fixes the callback (the browsed host is — see above), but it's correct to
leave it as the HTTPS URL for any self-links/redirects the app builds from it.

- `APP_URL` is defined in the compose **`environment:`** block
  (`docker-compose.yml` ~line 37) as `http://${ONECLI_BIND_HOST}:${ONECLI_APP_PORT}`.
  A Compose `environment:` entry **overrides `env_file:`**, so putting `APP_URL`
  in `/home/rs/.env` is **inert** (unlike `GATEWAY_BASE_URL`, which is *not* in the
  `environment:` block and therefore flows through). It must be edited in the
  compose file directly:
  ```bash
  cd /home/rs/.onecli && cp docker-compose.yml docker-compose.yml.bak2
  sed -i 's#^\(\s*APP_URL: \).*#\1https://nipogi-e3.tail8ea293.ts.net#' docker-compose.yml
  docker compose -p onecli up -d --force-recreate onecli
  docker exec onecli printenv APP_URL    # → https://nipogi-e3.tail8ea293.ts.net
  ```
- ⚠️ **Reverts on OneCLI reinstall** (the installer regenerates `docker-compose.yml`
  from `ONECLI_BIND_HOST`). Same caveat as the hardcoded postgres-port line.

### Client DNS — the `.ts.net` name doesn't resolve via the system resolver

Even with `accept-dns=true`, the tailnet has a **Split DNS route sending all
`ts.net.` queries to an external resolver (`199.247.155.53`)** that doesn't hold
MagicDNS records. So `nipogi-e3.tail8ea293.ts.net` resolves via the MagicDNS
resolver directly (`dig @100.100.100.100` works) but **not** via the OS resolver a
browser uses (`dscacheutil` returns nothing). The browser then can't reach the
HTTPS name.

Surgical fix on any machine that browses the dashboard (no tailnet-wide DNS change):

```bash
# /etc/hosts  — TS IP is stable
100.71.226.93 nipogi-e3.tail8ea293.ts.net
```

Nothing else needs the name: NanoClaw's `ONECLI_URL` and the agent egress proxy
(`GATEWAY_BASE_URL`) both use the raw IP `100.71.226.93`, so they're unaffected.
(Cleaning up the `ts.net → 199.247.155.53` split-DNS route in the admin console
would let machines resolve the name without the pin — left as-is for now since the
reason for that route is unknown.)

### Provider side (Trello)

In the Trello Power-Up admin for the API key, add the HTTPS origin to **Allowed
Origins**:

```
https://nipogi-e3.tail8ea293.ts.net
```

Then browse `https://nipogi-e3.tail8ea293.ts.net/connections` and connect. The
authorize URL's `return_url` should read
`https%3A%2F%2Fnipogi-e3.tail8ea293.ts.net%2Fv1%2Fapps%2Ftrello%2Fcallback`.
**Verified 2026-06-30: Trello connected** from a tailnet machine via the HTTPS URL.

### Security posture (unchanged by this work)

`tailscale serve` adds only a tailnet-only HTTPS path; it does **not** expose the
gateway publicly. The dashboard/vault remain **unauthenticated within the tailnet**
(`AUTH_MODE=local` — see "Auth model" above). Now that a live Trello OAuth token
(and the rest of the vault) sits behind it, any tailnet node can use those
credentials unauthenticated. To tighten without app-login lockout risk, scope the
ufw rule from "whole tailnet" to specific hosts and/or use Tailscale ACL grants to
restrict who can reach `:443/:10254/:10255` on nipogi-e3 (see "Adding another
machine" for the per-host ufw form). Real app auth requires `oauth` mode
(`NEXTAUTH_SECRET` + a working OAuth provider) — setting `NEXTAUTH_SECRET` alone
locks you out of the dashboard.
