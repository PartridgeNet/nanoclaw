# WhatsApp for rs-assistant: read/search + send via a bridge

**Status (2026-07-07): DONE + LIVE.** Bridge deployed to the Debian server (`100.108.5.11:4182`),
QR-paired, running under systemd, and wired into `rs-assistant`. Repo:
`github.com/PartridgeNet/whatsapp-bridge`. End-to-end verified: `rs-assistant`'s OneCLI env
reaches `/whatsapp/mcp` through the egress proxy with the bearer injected and gets live chat data.

**Goal:** `rs-assistant` (`ag-1782809385410-ql7ovb`, codex, Slack + Protonmail) reads/searches
the owner's personal WhatsApp and sends on their behalf, driven from Slack. Data-source + action
tool, **not** a conversational channel.

## Decisions (final)

- **Repo:** dedicated `PartridgeNet/whatsapp-bridge` (not in-tree, not monolith).
- **Host:** the home **Debian `server`** (tailnet), alongside the monolith backend + combined
  Rust `mcp-server` — *not* nipogi-e3, *not* the Mac. (Earlier drafts considered both.)
- **Artifact:** a single static **Bun-compiled musl binary** (`bun build --compile
  --target=bun-linux-x64-musl`), scp'd + run under systemd — same deploy shape as the Rust MCPs,
  no Node/npm/Docker added to the server. Baileys is pure-JS; its optional media deps (`jimp`,
  `sharp`, `link-preview-js`) are `--external`'d (text-only).
- **Reach from nanoclaw:** OneCLI egress proxy injects the bearer by host+path — identical to
  `classcharts` / `deploy`. Bound to the server's Tailscale IP, port `4182`, path `/whatsapp/mcp`.
- **Send gating:** confirm-in-Slack before every send. The bridge sends immediately when asked;
  confirmation is enforced by the per-group skill (mirrors the Protonmail rule).
- **No conversational adapter** — one linked-device session per number.

## Architecture

```
rs-assistant container (Mac)                 server (Debian, tailnet)
  MCP call ──HTTPS_PROXY=OneCLI──────────────►  whatsapp-bridge.service :4182
             (injects Authorization: Bearer)     /whatsapp/mcp  (bearer-gated)
                                                  ├─ Baileys linked-device session (auth/)
                                                  └─ SQLite message store (data/)
```

Tools: `list_chats`, `search_messages`, `get_history`, `read_chat`, `send_message`. `{ok,data}`
envelope like the monolith MCPs.

## What's done (in the whatsapp-bridge repo)

- Bun/Baileys service: connection lifecycle + reconnect, message→SQLite persistence, history sync.
- MCP-over-HTTP (Streamable, stateless JSON, bearer + Host allow-list). Validated end-to-end with
  a real MCP client: handshake, `tools/list`, list/search/send, and 401-on-missing-bearer.
- `pair` subcommand (QR or `--number` pairing code).
- `deploy/whatsapp-bridge.service` (hardened, `NoNewPrivileges` — no sudo needed) +
  `scripts/deploy-whatsapp-debian.sh` (modeled on `mcp/scripts/deploy-mcp-debian.sh`; refuses to
  start until paired).
- `bun run build` produces the x86-64 musl binary. tsc clean.
- `integration/rs-assistant-whatsapp-skill.md` — the confirm-before-send skill to install at wire-time.

## What was done (all complete)

1. Repo pushed: `github.com/PartridgeNet/whatsapp-bridge` (private). Deploy machine =
   `omarchy-gaming-pc` (SSH to `server.local`), not the Mac.
2. Deployed via `scripts/deploy-whatsapp-debian.sh` → systemd unit `whatsapp-bridge.service` on
   the server, bound to `100.108.5.11:4182`, path `/whatsapp/mcp`, bearer-gated.
3. QR-paired (pairing code failed repeatedly; QR worked). Session syncs live (~600 msgs on first sync).
4. OneCLI custom connection + rs-assistant access added (owner) → injects the bearer for the host+path.
5. Wired into rs-assistant: `ncl groups config add-mcp-server --name whatsapp --url http://100.108.5.11:4182/whatsapp/mcp`,
   plus `groups/rs-assistant/skills/whatsapp/SKILL.md`.

**Send model (updated 2026-07-07):** replaced confirm-every-message with **time-boxed, per-contact
send authorizations**, enforced in the bridge. `send_message` is default-deny — it refuses unless an
active grant exists for the recipient. Tools: `authorize_send(to, minutes)` (max 240m),
`list_send_authorizations`, `revoke_send`. Owner authorizes a contact + duration → agent calls
`authorize_send` once → sends freely (and handles replies autonomously) until it expires. Grants
persist in SQLite. The bridge hard-enforces contact scope + expiry; the agent still creates the grant
from the owner's instruction (same trust boundary as before, but coarser + safer).
6. Verified with `onecli run --agent ag-1782809385410-ql7ovb -- curl … /whatsapp/mcp` (no auth header
   from caller) → OneCLI injected the bearer, bridge returned live chats.

### Build/deploy gotchas hit (all fixed, baked into the repo)
- Deploy runs from `omarchy-gaming-pc`; `bun` is mise-managed → script resolves the mise shim.
- Target must be **`bun-linux-x64-baseline`** (glibc, no-AVX2). `-musl` = wrong loader; plain
  `bun-linux-x64` = `SIGILL` on the server's no-AVX2 CPU.
- Baileys' CJS default export is double-wrapped under `bun build --compile` → unwrap `makeWASocket`.
- Gate serve/send on `creds.me.id`, **not** `creds.registered` (QR sessions have registered=false).
- Pairing: request the code once per session; QR is more reliable than the code on this account.

## Constraints

- History reliable from pairing onward; older backlog best-effort (WhatsApp linked-device limit).
- `auth/` is a sending credential — gitignored, treat as secret.
- Reachability (container→server:4182 through the proxy, header injection) must be proven before
  wiring, not assumed.

## Reference

- Deploy pattern copied from: monolith `mcp/scripts/deploy-mcp-debian.sh`, `mcp/deploy/mcp.service`.
- Behavioral model: `groups/rs-assistant/skills/protonmail/SKILL.md` (confirm-before-send).
- Tailnet topology / egress proxy: `docs/onecli-remote-gateway.md`.
