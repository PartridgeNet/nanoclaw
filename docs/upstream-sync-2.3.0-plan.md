# Upstream sync plan — v2.1.53 → v2.3.0 (PartridgeNet fork)

**Status:** ✅ **DONE — cut over live 2026-09-07** (commit `c8082fa9`, branch `chore/upstream-sync-2.3.0`).
Host running v2.3.0; 6 upstream migrations applied to the live DB (ours skipped by name); Slack + mobile
channels up; deploy MCP over HTTPS:8443 survives the new config validation; OneCLI healthy; no boot errors.
Pre-cutover validation: host build + container typecheck clean; **host 2378 tests / container 429 tests
pass**; migration dry-run on a live-DB copy clean; container image build verified.
**Strategy:** extract-and-reapply (`/migrate-nanoclaw` model), NOT a merge. Hybrid two-track reapply.

**Cutover gotcha (recorded):** the systemd unit runs `node dist/index.js` (a compiled build), NOT tsx — so
after `git reset` you MUST `pnpm run build` before restart, or the service silently runs stale old code (the
first restart ran old 2.1.53 and skipped migrations until dist/ was rebuilt).

**Post-cutover follow-ups (non-blocking):** (a) `/migrate-slack-agents` to record the stay-classic choice;
(b) Slack sender-name needs the `chat:write.customize` bot scope (owner action) to render `Assistant [group]`;
(c) per-group images (partridgenet-dev, rs-assistant) are on the old base — rebuild on next `--rebuild`; the
mounted agent-runner is already new, so cosmetic; (d) backups kept: `data/v2.db.pre-sync-*` +
`data/v2.db.cutover-*`, git tag `pre-sync-a81f8f80-*`.

## Why not a merge

- Upstream is **500 commits** ahead (v2.1.53 → v2.3.0). Our fork carries **66 commits / 97 files**.
- **44 files were changed on both sides** — and the colliding ones are exactly the files upstream
  *rewrote or moved wholesale*:
  - `src/container-runner.ts` / `container-runtime.ts` / `container-config.ts` → new **`src/drivers/`** seam;
    helpers we patch (`buildContainerArgs`, `hostGatewayArgs`, `readonlyMountArgs`, `cleanupOrphans`) moved.
  - `src/claude-md-compose.ts` → **renamed** `src/project-doc-compose.ts` (signature changed).
  - Central DB → **async `DbDriver`**; agent **mailbox seam**; host **lifecycle registry**.
- A squashed diff / merge still references the *old* file shapes on those surfaces → unresolvable or
  silently-wrong. So we re-derive the colliding third by intent, and only squash-replay the safe two-thirds.

## Scope facts (measured 2026-09-07)

- Node host: v22.23.1 ✓ (meets new Node-22 requirement — no action).
- `@onecli-sh/sdk`: already `2.2.1` = upstream ✓.
- OneCLI gateway: remote fork image `onecli-fork:v1.39.0-ebay-trading` on nipogi-e3, **decoupled** from
  `versions.json` pin (1.36.0→1.41.0). Serves `/v1`. Do **not** run the standard gateway upgrade — see
  `docs/onecli-remote-gateway.md`. Likely no gateway change needed.
- Slack patch already at `patches/@chat-adapter__slack@4.29.0.patch` = upstream's new Chat-SDK pin ✓
  (still re-verify it applies against 4.29.0 source).

---

## Two-track split of our 66 commits

### Track A — squash + replay (additive, upstream did not touch these files)

Safe to capture as one squashed patch and `git apply` onto the clean worktree:

- **Docs (all clean):** `docs/browser-session-export.md`, `docs/host-redeploy.md`, `docs/live-browser.md`,
  `docs/mobile-channel.md`, `docs/onecli-fork-reconciliation.md`, `docs/onecli-remote-gateway.md`,
  `docs/slack-agent-sender-name.md`, `docs/whatsapp-rs-assistant-plan.md`, `classcharts-mcp-spec.md`,
  this file.
- **Scripts (all clean):** `scripts/browser-session-*.{mjs,sh}`, `scripts/chrome-devtools-bridge.mjs`,
  `scripts/live-chrome*.sh`, `scripts/install-live-chrome-autostart.sh`,
  `scripts/classcharts-mcp-set-credentials.sh`, `scripts/protonmail-set-credentials.sh`,
  `scripts/host-redeploy.sh`, `scripts/rebuild-group-image.ts`, `scripts/update-cleo-agent-pkgscript.ts`.
- **Container skill / instructions:** `container/skills/onecli-gateway/SKILL.md`,
  `container/agent-runner/src/mcp-tools/core.instructions.md`.
- `.env.example` additions.

**NOT in Track A even though upstream didn't touch them:**
- `.claude/scheduled_tasks.lock` — should be gitignored, not replayed (already untracked in commit `6cd6511`).
- All `codex*` files → **dropped** (Codex retired — see Track C). Not replayed, not reapplied.
- `src/channels/mobile*`, `src/channels/slack.ts`, `src/channels/index.ts`, our DB migrations → **Track B/D**.

### Track B — re-derive by intent (collides with upstream rewrites) — HIGHEST RISK

The 44 overlapping files. Reapply against the *new* architecture, guided by the breaking-change guides:

1. **Container / OneCLI remote-gateway credential-proxy wiring** — **RESOLVED, low residual risk.**
   Upstream v2.3.0 already built the bridge our fork needed: `src/gateway-providers/onecli.ts` performs
   the *identical* wiring (`ensureAgent` + `applyContainerConfig(args,{addHostMapping:false})` +
   not-applied-is-fatal) and parses the SDK's argv into typed spec lanes (`contributedEnv` + classed
   mounts) before admission. So we do NOT carry a parallel driver — we adopt upstream's and re-express
   only the fork-specific deltas. See **the six-hack table** below for the full analysis. Net residual:
   two `spec.env` entries, one Dockerfile line, one small fork-local Docker-driver addition (hack 2).
   Still run `bun scripts/detect-driver-migration.ts` to catch any other moved-helper imports.
2. **Central DB async** — await our custom central-DB calls (`src/db/*`, `src/session-manager.ts`,
   `src/delivery.ts`). Follow `docs/central-db-async-migration.md`.
3. **Agent mailbox seam** — `277a43a6` (reactions → synthetic inbound; reconcile vs *closed inbound-kind
   set*), `1819803f` (A2A isolation + `new_thread`; reconcile vs *explicit `to`* task delivery),
   `1569376f` (async `ask_user_question`). Follow `docs/agent-mailbox-seam-migration.md`.
4. **project-doc rename** — `1dd9a3ba`/`8a8d6e1d`/`1ea7f092` + the STOP banner: fork notes move into the
   `DEFAULT_PROJECT_DOC` path; repoint any `composeGroupClaudeMd`/`claude-fragments` refs.
5. **Host lifecycle registry** — move any `onShutdown()`/`getShutdownCallbacks()` off `response-registry.ts`.
6. **Scheduled tasks → `ncl tasks`** — `91a621b9` scheduling warning: rehome onto the new task model.
7. **Owner-shared credentials / 2FA-in-chat** — `698bed33`/`a366c929`: reconcile vs new admission model.
8. **Slack per-agent sender name** — `53578557`/`11f4944e`: re-verify `patches/@chat-adapter__slack@4.29.0.patch`
   applies; re-run `/add-slack` (formatting moved to `channels` branch). See `docs/slack-agent-sender-name.md`.
9. **Container build extensions** — `8e290125` (`packages_script`), `61f990f5` (`packages_env` + live-chrome
   download dir), `a155c569` (`--no-cache` per-group builds). Per-group image building is now a driver
   `imageBuild` capability (`ncl groups restart --rebuild` refuses on drivers lacking it). Re-express these
   through that capability rather than the old `buildAgentGroupImage` path. Rides the migration renumber for
   the `packages_script`/`packages_env` columns.

### Container credential-proxy: the six hacks (Track B #1 detail)

Our fork carried six argv-level hacks around the OneCLI proxy. Verdicts after inspecting the SDK (2.2.1,
still argv-mutating) and upstream's `gateway-providers/onecli.ts` bridge:

| # | Hack | Originally for | Verdict |
|---|------|----------------|---------|
| 1 | `NO_PROXY=localhost,127.0.0.1,::1,host.docker.internal` (`469af226`,`2cfa50bf`) | Gateway injects `HTTP(S)_PROXY` but no `NO_PROXY`; loopback health-checks + the live-browser bridge (`host.docker.internal`, undici `EnvHttpProxyAgent`) got misrouted through the proxy | **KEEP** → move to `spec.env` (non-secret). SDK still never sets it; live-browser + loopback still need it. |
| 2 | `--add-host host.docker.internal:host-gateway` (upstream `#798`) | Reach a host-side service on Linux (built-in on Docker Desktop only) | **KEEP — only durable fork-local touch.** Upstream driver adds no host mapping + gateway-provider hard-codes `addHostMapping:false`. Needed for the host live-browser bridge → small fork-local Docker-driver addition. |
| 3 | `onecli.applyContainerConfig(args,…)` mutating our argv (`#798`,`78e7d9c5`) | Inject `HTTPS_PROXY` + CA mount + credential stubs for per-request injection | **DROP → adopt upstream.** `gateway-providers/onecli.ts` does the identical call and types the result into spec lanes. Delete our in-line call. |
| 4 | `auth.json :ro→:rw` argv rewrite (`27bb31bd`) | Codex wrote a refreshed token back to the `:ro` stub → `EROFS` | **DROP entirely.** Codex retired (see Track C) — no writable-stub need remains. |
| 5 | git `http.proxyAuthMethod=basic` + `GIT_SSL_CAINFO` entrypoint shim (`78e7d9c5`,`feece1e5`) | git/libcurl won't preemptively send `Proxy-Authorization` on CONNECT (401 on `git push`) and ignores the SDK's `SSL_CERT_FILE` (TLS fail under MITM) — the cleo-agent push path | **KEEP, re-expressed.** Entrypoint is driver-owned now: bake `git config --system http.proxyAuthMethod basic` into the Dockerfile; set `GIT_SSL_CAINFO=/tmp/onecli-combined-ca.pem` as a static `spec.env` path pointer (admission-exempt). |
| 6 | `SSL_CERT_FILE` (combined CA bundle) | Proxied HTTPS validates against the gateway's MITM CA | **DROP — never ours.** SDK injects it; upstream's gateway-provider carries it into `contributedEnv`. |

Net: hacks 3, 4, 6 vanish; 1 and 5 become a `spec.env` entry + one Dockerfile line; 2 is the only lasting
fork-local delta, and only because of the live-browser feature.

### Track C — DROP Codex entirely (no reapply)

Decision (2026-09-07): all active agents run **Claude**. The 4 active groups (`partridgenet-dev`,
`cleo-agent`, `NanoClaw`, `rs-work-pa`) are Claude; 17 groups still carry `provider=codex` but are **dormant**
(last session 2026-08-16 … 2026-06-30) and treated as **retired**.

- Do **not** reapply `/add-codex`. Do not carry any `codex*` files
  (`src/providers/codex*`, `setup/providers/codex*`, `container/agent-runner/src/providers/codex*`,
  `exchange-archive*`) — they simply don't exist on the clean upstream base.
- Drop the codex-only fork commits: `d4e2c27f` (stream-disconnect), `926b83fe` (turn-timeout),
  `1a240447` (codex bump), and hack 4.
- The 17 dormant codex groups are left as-is; if one is ever revived it won't spawn until switched to
  Claude (`ncl groups config update --id <id> --provider claude`) — accepted.
- **Remote-HTTP MCP support** (`5e910d5f`, `d5adfca3`) — **DROP both; upstream has it, more completely.**
  v2.3.0 supports `url` / `type: http|streamable-http` in `container-config.ts`, `url` XOR `command` in
  `self-mod.ts` (with credential-in-URL rejection), and `ncl groups config add-mcp-server --url`. This is
  load-bearing for partridgenet-dev's deploy MCP — see the deploy-MCP plain-HTTP verification below.

### Track D — fork-unique, reapply carefully

- **Mobile channel (#6)** — `8917ba74`: `src/channels/mobile.{ts,test.ts}`, barrel import,
  `docs/mobile-channel.md`, migration (renumber — see hazard below). No upstream equivalent. Reconcile
  vs new Chat-SDK 4.29.0 pin + channel-skills-single-source-of-truth model.
- **Our DB migrations** — `packages-script`, `packages-env`, `mobile-channel`: append to the `migrations`
  array unchanged (names are the dedup key — do not rename); files/version-hints → `026`–`028`. See the
  resolved Migrations section — no collision.

---

## Migrations — RESOLVED (no collision; the runner dedupes by NAME)

The "number collision" was a false alarm. `runMigrations` (`src/db/migrations/index.ts`) keys applied
state on `schema_version.name` (unique index `idx_schema_version_name`), NOT on the filename prefix or the
`version:` field — those are ordering hints only, and the stored `version` column is auto-assigned as an
applied-order counter (`MAX(version)+1`). Confirmed against the live `data/v2.db`: our three are already
recorded by name — `packages-script`, `packages-env`, `mobile-channel` — and upstream's new migrations use
entirely distinct names (`container-config-timezone`, `approval-question`, `messaging-group-detached`,
`approvals-instance`, `host-coordination`, `container-config-speed`). No name overlap → no re-run.

**Decision:** adopt upstream's migrations as-is; **append our three custom migrations to the end of the
`migrations` array**, unchanged. Then:

- **NEVER change the `name` field** of `packages-script` / `packages-env` / `mobile-channel` — that string
  is the dedup key; renaming it makes the runner treat it as new and re-run → duplicate-column error. This
  is the *only* real hazard, and it's avoided by leaving the names alone.
- Rename the *files* + bump the `version:` hints to `026`/`027`/`028` for tidiness (drops the duplicate
  `019-`/`020`/`021` prefixes that would otherwise sit alongside upstream's) — cosmetic, since neither is a
  dedup key.
- Place them after upstream's `container-config-speed` in the array so a **fresh** DB runs them last (array
  order is execution order; `packages-env` needs `014-container-configs`, `mobile-channel` needs the
  channel tables). On the **live** DB nothing re-runs (all three already applied by name).
- Sanity-check on a throwaway fresh DB that the array runs clean end-to-end; the live DB is a no-op here.

## Deploy-MCP plain-HTTP URL — DONE (moved to HTTPS on :8443, 2026-09-07)

**Why:** upstream's `parseMcpServerConfig` (`src/container-config.ts`) enforces **HTTPS except loopback** and
re-validates stored config on **every spawn** (`materializeContainerJson` → `sanitizeStoredMcpServers` →
`parseMcpServerConfig` per entry → failing entry **dropped + `log.warn`'d**). So the plain
`http://100.127.85.65:4180/deploy/mcp` would be silently stripped post-upgrade, killing partridgenet-dev's
deploy tools. Fixed pre-emptively on the live 2.1.53 system so it carries through the sync.

**Done (2026-09-07):**
- beelink: `tailscale serve --bg --tls-terminated-tcp=8443 tcp://127.0.0.1:4180`; mcp rebound to
  `0.0.0.0:4180` (needs a loopback listener for serve; other apps still use the tailnet-IP bind). Setup
  script: `beelink:/home/rs/mcp-serve-finalize.sh`.
- nipogi: OneCLI `Deploy MCP (beelink)` secret host_pattern `100.127.85.65`→`beelink-mini-s.tail8ea293.ts.net`;
  partridgenet-dev's `monolith-deploy` URL → `https://beelink-mini-s.tail8ea293.ts.net:8443/deploy/mcp`
  (DB + on-disk container.json). Gateway container resolves the FQDN natively (no `extra_hosts` needed).
- Verified from nipogi: direct → 401; via OneCLI proxy with partridgenet-dev's `access_token` → 405 (auth OK).

**⚠️ Gotcha that cost hours** (now in the deploy-MCP memory): beelink's `monolith-backend` owns `*:443`
(the `partridgenet.io` origin), and `mcp-server` on `:4180` has NO SPA handler — so a "404 App not found"
means the request hit monolith-backend, not mcp. `tailscale serve` only intercepts traffic from OTHER
tailnet peers, so **always verify from nipogi, never with a local curl on beelink** (which hits
monolith:443 directly). Hence the dedicated `:8443` (never `:443`) and the loopback serve target.

**Follow-ups (optional):** (a) real `deploy_status` from partridgenet-dev via Slack for a live end-to-end
tick; (b) mcp's `0.0.0.0:4180` bind now also exposes it on the home LAN (bearer-gated) — could tighten if
the other beelink MCP apps are later moved to HTTPS too.

---

## Breaking-change migration sequence (14 total)

Run after the reapply, in the worktree, in this order (detect-scripts noted):

1. Node 22 — **already satisfied**, skip.
2. project-doc-compose rename — Track B #4.
3. Central DB async (`DbDriver`) — Track B #2. `docs/central-db-async-migration.md`.
4. Agent mailbox seam — Track B #3. `docs/agent-mailbox-seam-migration.md`.
5. Container driver seam — Track B #1. `bun scripts/detect-driver-migration.ts`.
6. Host lifecycle registry — Track B #5. `docs/host-lifecycle-migration.md`.
7. Scheduled tasks → `ncl tasks` — Track B #6. `docs/ncl-tasks-migration.md`.
8. Task delivery explicit `to` — Track B #3 (A2A/reactions). Rebuild image + restart + clear/compact sessions.
9. Templates → Agent Plugins 1.0 — re-fetch templates from registry; `docs/templates.md`.
10. `/migrate-slack-agents` — run; **choose stay-classic** (records the choice, satisfies the gate).
11. slack/whatsapp-formatting moved to `channels` branch — re-run `/add-slack` (we have Slack).
12. Chat SDK pinned 4.29.0 — re-run `/add-slack` and reconcile the mobile channel to the pin.
13. Hardened/Echo image — **stay on local build** (we need custom Dockerfile layers). Document the choice.
14. OneCLI SDK/gateway — SDK already 2.2.1; gateway is remote fork serving `/v1`. **Do not** run standard
    upgrade. Verify `/v1/health` post-cutover.

---

## PartridgeNet guardrails

- **Live family infrastructure.** Agents are down during the swap + mandatory full container rebuild
  (`--no-cache` per group). Schedule a low-traffic maintenance window; announce it.
- **Back up first:** `data/v2.db` (upstream's new migrations apply to the live DB on first start; our three
  are no-ops — already applied by name) and the per-session DBs under `data/v2-sessions/`.
- **OneCLI:** remote fork gateway on nipogi-e3 — leave it alone unless `/v1/health` fails. See
  `docs/onecli-remote-gateway.md` / `docs/onecli-fork-reconciliation.md`.
- **Container image:** local build with our custom layers; not the Echo hardened image.
- **Cleo-agent / deploy-MCP** are downstream consumers — smoke-test after cutover.

---

## Staged execution (worktree-based, validate before swap)

- **Phase 0 — Prep:** clean tree; `git fetch upstream --prune`; backup branch+tag; back up `data/v2.db`
  + session DBs; announce window. **Pre-req (beelink-mini-s):** serve the deploy MCP over HTTPS and
  re-point all groups' `monolith-deploy` URLs (see the ⚠️ Deploy-MCP section) — done + verified before the
  swap, since upstream will strip the plain-HTTP URL.
- **Phase 1 — Catalogue:** finalize Track A/B/C/D lists into `.nanoclaw-migrations/guide.md` (intent +
  snippets for every Track B/C/D item). This doc is the seed.
- **Phase 2 — Clean base:** `git worktree add .upgrade-worktree upstream/main --detach`.
- **Phase 3 — Reapply:**
  - Track C: nothing — Codex dropped (no `/add-codex`).
  - Channels/skills: re-run `/add-slack` in the worktree (Track B #8); reapply the mobile channel (Track D).
  - Track A: apply the squashed additive patch.
  - Track B/D: re-derive each item against the new architecture; append our 3 migrations (unchanged names),
    then sanity-run the array against a throwaway fresh DB.
- **Phase 4 — Breaking-change migrations:** run the 14-step sequence; run each detect-script.
- **Phase 5 — Validate in worktree:** `pnpm install && pnpm run build && pnpm test`;
  container typecheck; `./container/build.sh`.
- **Phase 6 — Live test (optional):** symlink `data/`,`groups/`,`.env` into worktree, `pnpm run dev`,
  send a real message, confirm, stop.
- **Phase 7 — Swap + cutover:** stop service; swap worktree → main (`git reset --hard <upgrade-commit>`);
  `pnpm exec tsx scripts/upgrade-state.ts set "" migrate-nanoclaw`; restart service; verify agents reply,
  OneCLI `/v1/health`, deploy-MCP + cleo-agent smoke tests.

## Rollback

- Code: `git reset --hard <backup-tag>` (backup branch also kept).
- DB: restore the `data/v2.db` + session-DB backups (needed because migrations mutate them on first start).

## Open questions — all resolved (2026-09-07)

1. ~~Are `5e910d5f` / `d5adfca3` already upstream?~~ **YES — drop both.** Upstream v2.3.0 ships remote-HTTP
   MCP support more completely (see Track C). New follow-on: verify the deploy-MCP plain-HTTP URL survives
   upstream's HTTPS rule (its own ⚠️ section above).
2. ~~Migration-collision fix (idempotent vs applied-set reconciliation)?~~ **Neither needed** — the runner
   dedupes by `name`, our names are distinct and already applied. Append unchanged; never rename. See the
   resolved Migrations section.
3. ~~Sanctioned lane for our egress-proxy + CA-bundle wiring?~~ **YES** — `src/gateway-providers/onecli.ts`
   is upstream's bridge; we adopt it. Only fork-local driver delta is hack 2 (`host.docker.internal`).

Verified follow-ons (both now closed):
- Config materialize/load path **does** re-validate stored MCP config on every spawn (confirmed) — so the
  deploy-MCP plain-HTTP URL is a **confirmed breakage**, fixed by serving it over HTTPS (⚠️ section above).
  This is a pre-cutover prerequisite on beelink-mini-s, folded into Phase 0.
