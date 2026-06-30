# Per-agent Slack sender name (`NanoClaw [<agent-group>]`)

PartridgeNet fork customization. By default every Slack message NanoClaw posts
shows the same sender ("NanoClaw"), regardless of which agent group produced it.
This change makes the **replying agent group's name appear in the Slack sender**,
e.g. `NanoClaw [meal-planner]`, so it's obvious at a glance which agent is
talking in a shared workspace. Built 2026-06-30.

> Background on channels and the Chat SDK bridge lives in the root `CLAUDE.md`
> ("Channels and Providers"). This doc only covers the sender-name feature: how
> it's wired, the dependency patch it relies on, the Slack scope it requires, and
> how to deploy/maintain it.

## What the user sees

A Slack message from the `meal-planner` agent group is posted with the bot
display name **`NanoClaw [meal-planner]`** instead of `NanoClaw`. Each agent
group gets its own bracketed name; the bot icon is unchanged.

## Why it needs two parts

Slack's `chat.postMessage` supports a per-message `username` override, but two
gaps sit between "the host knows the agent name" and "Slack renders it":

1. **The name isn't threaded to the adapter.** The agent group name
   (`agent_groups.name`) is known on the host at delivery time, but the channel
   delivery interface (`ChannelDeliveryAdapter.deliver` → `ChannelAdapter.deliver`
   / `OutboundMessage` → the Chat SDK bridge) carried no sender identity.
2. **The Slack adapter strips it.** The pinned `@chat-adapter/slack@4.29.0`
   package builds its Slack payload via `SlackFormatConverter.toSlackPayload`,
   which returns only `{ text }` / `{ markdown_text }` — any `username` on the
   message object is dropped before `chat.postMessage` is called.

So the fix threads the **raw agent name** through the (channel-agnostic) delivery
interface, formats the Slack-specific `NanoClaw [<name>]` string in the Slack
wiring, and patches `@chat-adapter/slack` to forward `username` into the API call.

## Data flow

```
agent_groups.name  ("meal-planner")
   │  src/delivery.ts  deliverMessage(): getAgentGroup(session.agent_group_id)?.name
   ▼  → deliveryAdapter.deliver(..., senderName)
ChannelDeliveryAdapter.deliver   (src/delivery.ts interface)
   ▼  src/channels/channel-registry.ts  createChannelDeliveryAdapter()
adapter.deliver(platformId, threadId, { kind, content, files, senderName })
   ▼  OutboundMessage.senderName   (src/channels/adapter.ts)
Chat SDK bridge deliver()   (src/channels/chat-sdk-bridge.ts)
   │  if config.senderNameFormat && message.senderName:
   │     username = config.senderNameFormat(message.senderName)  // "NanoClaw [meal-planner]"
   ▼  adapter.postMessage(tid, { markdown|card, ...{ username } })
@chat-adapter/slack postMessage()   (PATCHED)
   ▼  forwards username/icon into chat.postMessage(...)
Slack renders sender as "NanoClaw [meal-planner]"
```

Only Slack opts in (via `senderNameFormat` in `src/channels/slack.ts`). Other
chat-SDK channels leave the formatter unset, so no `username` is emitted and they
behave exactly as before — the extra optional field is harmless for adapters that
ignore it.

## Files changed (fork code, in git)

| File | Change |
|------|--------|
| `src/channels/adapter.ts` | Added optional `senderName?: string` to `OutboundMessage` |
| `src/delivery.ts` | `ChannelDeliveryAdapter.deliver` gained a trailing `senderName?` param; `deliverMessage` resolves `getAgentGroup(...).name` and passes it. `system`/`agent` kinds return earlier, so internal traffic is unaffected |
| `src/channels/channel-registry.ts` | `createChannelDeliveryAdapter().deliver` threads `senderName` into the `OutboundMessage` |
| `src/channels/chat-sdk-bridge.ts` | New opt-in `senderNameFormat?: (agentName: string) => string` config; when set and a `senderName` is present, stamps `username` on the text, display-card, and ask_question payloads |
| `src/channels/slack.ts` | Passes `senderNameFormat: (name) => \`NanoClaw [${name}]\`` into the bridge — keeps the branding next to the Slack wiring, not in core |

Tests live alongside: `src/channels/chat-sdk-bridge.test.ts` (username stamped on
text + card paths; omitted with no formatter / no senderName),
`src/channels/channel-registry.test.ts` (senderName threaded into the
`OutboundMessage`), `src/delivery.test.ts` (agent group name passed as senderName).

## The dependency patch

Because the relevant code is in the compiled `@chat-adapter/slack` package (not in
`src/`), the forwarding is added with a **`pnpm patch`**:

- Patch file: `patches/@chat-adapter__slack@4.29.0.patch`
- Registered in `pnpm-workspace.yaml` under `patchedDependencies`:
  ```yaml
  patchedDependencies:
    '@chat-adapter/slack@4.29.0': patches/@chat-adapter__slack@4.29.0.patch
  ```
- What it does: in `dist/index.js` `postMessage(threadId, _message)` it derives an
  `authorship` object from `_message` (`username` / `icon_emoji` / `icon_url`) and
  spreads it into **both** `chat.postMessage` calls (the blocks/card path and the
  text path). `as_user` is left unset (Slack's `username`/icon overrides require it
  to be falsy, which is the default with a bot token + `chat:write.customize`).

Supply-chain note: this uses only `patchedDependencies` — it does **not** touch
`minimumReleaseAgeExclude` or `onlyBuiltDependencies`, and introduces no new
package versions, so it stays within the repo's pnpm policy
(see `CLAUDE.md` → "Supply Chain Security").

To re-create or amend the patch:
```bash
pnpm patch @chat-adapter/slack@4.29.0           # opens an editable copy, prints its path
# edit dist/index.js in the printed directory
pnpm patch-commit '<printed-dir>' --config.confirmModulesPurge=false
```

## Slack prerequisite (workspace side — owner action)

Slack only honors a per-message `username` if the bot token has the
**`chat:write.customize`** scope. Without it, `chat.postMessage` returns
`missing_scope` and delivery fails.

1. Slack app config → **OAuth & Permissions** → add Bot Token Scope
   `chat:write.customize` (alongside the existing `chat:write`).
2. **Reinstall** the app to the workspace so the installation picks up the scope.

**Reinstalling does not change the bot token.** Re-authorizing an existing
installation in the same workspace keeps the same `xoxb-…` token and attaches the
new scope to it — so `SLACK_BOT_TOKEN` in `.env` does **not** need updating. (The
token only changes on a full uninstall/recreate or if token rotation is enabled.)
Verify without printing the secret:
```bash
tok=$(grep -E '^SLACK_BOT_TOKEN=' .env | head -1 | sed -E 's/^SLACK_BOT_TOKEN=//; s/^"//; s/"$//')
curl -s -D - -o /dev/null -H "Authorization: Bearer $tok" https://slack.com/api/auth.test \
  | grep -i '^x-oauth-scopes:'    # confirm chat:write.customize is listed
```
(Confirmed present on the PartridgeNet `nanoclaw` bot, team PartridgeNet, 2026-06-30.)

## Deploy

The host runs the **compiled** `dist/index.js`, so changes need a build + a
restart of the slug-scoped launchd service (this copy is `com.nanoclaw-v2-32406a8d`,
running from `/Users/rob.s/src/PartridgeNet/nanoclaw`):

```bash
pnpm install            # applies the pnpm patch (see sandbox note below)
pnpm run build          # tsc → dist/
launchctl kickstart -k gui/$(id -u)/com.nanoclaw-v2-32406a8d   # macOS, this copy
```

After restart, confirm in `logs/nanoclaw.log`: `Chat SDK bridge initialized`
(slack) → `Channel adapter started channel=slack` → `Webhook server started …
adapters=["slack"]`, and no `missing_scope` / `postMessage` errors in
`logs/nanoclaw.error.log`.

## Verify end-to-end

1. Trigger a reply from a Slack chat wired to one agent group → sender shows
   `NanoClaw [<that-group-name>]`.
2. Repeat from a chat wired to a different agent group → a different bracketed
   name, proving it's per-agent, not a static rename.
3. A non-Slack channel (if installed) still delivers normally (username ignored).

## Gotchas / maintenance

- **`dist/` is what runs.** Any change to the sender-name logic needs
  `pnpm run build` + the `launchctl kickstart` above; editing `src/` alone does
  nothing for the live host.
- **Don't lose the patch.** A future `/add-slack` re-run or a `pnpm install` that
  purges modules must keep the `patchedDependencies` entry — that's what
  re-applies the patch. If `@chat-adapter/slack` is ever bumped off `4.29.0`, the
  patch must be re-created against the new version (the version is pinned in both
  the entry key and the patch's git hashes).
- **Native rebuild under the command sandbox.** `pnpm patch-commit` /
  reinstall rebuilds `better-sqlite3`, which fails under the agent command
  sandbox with `EPERM` on `~/.npm` and `~/Library/Caches/node-gyp`. Run the
  install/rebuild with the sandbox disabled (`pnpm rebuild better-sqlite3` to
  recover if a binary goes missing). Likewise `launchctl kickstart` needs the
  sandbox disabled.
- **Files-only messages.** Messages with attachments but no text/card post via
  `files.upload`, not `chat.postMessage`, so they don't carry the custom sender
  name. Accepted limitation — these are rare and usually accompany text.
