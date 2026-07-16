# Browser session export (local login → remote agent browsing)

Give an agent access to a website that needs a login, without ever putting
credentials in chat, env, or the vault. You log in **once** in a real Chrome
or Brave window on your Mac; the resulting session (cookies + localStorage) is
copied to the NanoClaw host at `rob.s@assistant`, exported into the agent
group's workspace, and the agent's own headless `agent-browser` reuses it.

This is the ergonomic, general version of the "session export" browser-auth
approach. It complements — but does not replace — the **live-browser** approach
(`scripts/tesco-chrome.sh`), which is still required for sites with strong bot
detection (see the caveat at the end).

## How it works

```
scripts/browser-session-export.sh <group> [name] [login-url]
   │
   ├─ launches real Google Chrome, or Brave if Chrome is not installed,
   │  (headed, throwaway isolated profile,
   │  loopback DevTools port) at the login URL
   ├─ you log in (username, password, MFA, "remember me"), press Enter
   ├─ browser-session-export.mjs connects over CDP and writes a Playwright
   │  storageState JSON to a local temp file
   ├─ scp uploads the session to rob.s@assistant, where it lands at
   │  groups/<group>/.browser-sessions/<name>-exported-session.json  (mode 600)
   └─ tailscale ssh runs browser-session-scaffold.mjs on rob.s@assistant to
      update the group's session manifest and (re)write the per-group
      `browser-session` skill
```

The session file lands in the remote group workspace, so it surfaces **live**
inside the container at
`/workspace/agent/.browser-sessions/<name>-exported-session.json` — no mount
wiring, no image rebuild, no restart. The agent loads it with
`agent-browser state load <file>` and then browses as the logged-in user.

Because each export uses a **throwaway isolated browser profile**, only the site
you log into is captured — auth stays scoped to exactly the sites you choose.
The launcher prefers Chrome, then falls back to Brave. It checks standard macOS
app locations, common Linux commands/paths, and Flatpak Brave. For unusual
installs, set `BROWSER_EXPORT_BROWSER=/path/to/browser`.
The machine running the script must also be online in the same Tailscale
tailnet, because the final session file is copied to `rob.s@assistant`.

## Usage

```bash
# Interactive (prompts for name + URL):
bash scripts/browser-session-export.sh personal-shopper

# Fully specified:
bash scripts/browser-session-export.sh personal-shopper amazon https://www.amazon.co.uk/
```

A Chrome or Brave window opens; log in, leave it on a signed-in page, return to
the terminal and press Enter. The session is captured locally, copied to
`rob.s@assistant`, and the group is ready.

Re-run the same command whenever a session expires (the agent will tell you it
landed on a login page).

If the script reports that this machine is offline in Tailscale, check:

```bash
tailscale status --self --peers=false
tailscale up
```

## What the agent sees

The export scaffolds `groups/<group>/skills/browser-session/SKILL.md`, listing
every available session (name, site, file path, export date) and telling the
agent to:

- `agent-browser state load <file>` before `agent-browser open <url>`;
- **never** enter credentials or solve a login/CAPTCHA itself;
- stop and ask the user to re-export when a session has expired;
- confirm before any irreversible or outward action (the session acts as the
  real, logged-in user).

Sessions are also listed machine-readably at
`/workspace/agent/.browser-sessions/index.json`.

## Files

| File | Purpose |
|------|---------|
| `scripts/browser-session-export.sh` | Local launcher: validate the remote group, launch Chrome, wait for login, capture, upload, scaffold |
| `scripts/browser-session-export.mjs` | Zero-dep CDP capture → Playwright `storageState` JSON (Node 22 global `WebSocket`) |
| `scripts/browser-session-scaffold.mjs` | Run on `rob.s@assistant` to update the group's session manifest + rewrite the per-group skill |
| `rob.s@assistant:/Users/rob.s/src/PartridgeNet/nanoclaw/groups/<group>/.browser-sessions/*-exported-session.json` | Captured sessions (mode 600, gitignored) |
| `rob.s@assistant:/Users/rob.s/src/PartridgeNet/nanoclaw/groups/<group>/.browser-sessions/index.json` | Session manifest |
| `rob.s@assistant:/Users/rob.s/src/PartridgeNet/nanoclaw/groups/<group>/skills/browser-session/SKILL.md` | Per-group skill teaching the agent to use its sessions |

## Security

- Session files hold **live auth tokens**. They are captured to a local temp
  file, uploaded over `scp`, written mode `600` on `rob.s@assistant`, live under
  `groups/*` (gitignored) and match `*-exported-session.json` /
  `.browser-sessions/` in `.gitignore` — never commit them, never echo their
  contents.
- Credentials themselves never touch disk, chat, or env — only the resulting
  session cookies do, and only inside the group workspace.
- The capture uses the host's own installed Chrome or Brave browser, so the
  exported session carries a consistent, real browser fingerprint.

## Caveat: anti-bot sites

Sites with aggressive bot detection (e.g. **Tesco**) fingerprint the browser and
block a fresh headless `agent-browser` even with a perfectly valid session.
Session export does **not** work for those — they need the live-browser approach
(`scripts/tesco-chrome.sh` + `chrome-devtools-mcp`, driving a persistent
logged-in Chrome). If a site consistently blocks the agent despite a fresh
export, that's the signal to switch it to the live-browser path.
