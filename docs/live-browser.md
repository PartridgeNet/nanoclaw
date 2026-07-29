# Live browser

Give an agent a persistent, signed-in browser it can drive via CDP — for
sites that block headless browsers, require real persistent sessions
(Google's device-bound session checks, Tesco, etc.), or where you want the
agent to browse as you.

Each live-browser group has:
- A **persistent Chromium profile** at `~/.nanoclaw-live-chrome/<group>/`
  that holds your cookies, localStorage, and account sessions.
- A **headless Chromium service** (`nanoclaw-live-chrome-<group>.service`)
  running that profile. Headless mode is required because Chromium on
  Wayland/Linux does not bind `--remote-debugging-port` in headed (windowed)
  mode — the DevTools HTTP server is silently omitted. Headless mode binds
  the port immediately and still reads/writes the persistent profile.
- A **DevTools bridge** (`scripts/chrome-devtools-bridge.mjs`) that proxies
  CDP traffic from the agent container (`host.docker.internal:<bridge-port>`)
  to Chromium's loopback-only debug port, rewriting the `Host` header so
  Chromium's DNS-rebinding protection accepts the request. On Linux, Docker
  containers reach the host via the docker bridge interface (`172.17.0.1`), not
  loopback, so the bridge listens on `0.0.0.0`.

```
agent container
  └─ chrome-devtools-mcp
       └─ http://host.docker.internal:<bridge-port>
            └─ chrome-devtools-bridge (loopback, host)
                 └─ http://127.0.0.1:<chrome-port>  (Chromium headless, --remote-debugging-port)
                      └─ ~/.nanoclaw-live-chrome/<group>/  (persistent profile: cookies, sessions)
```

## Port numbering

Each group has a **chrome-port** (Chromium's debug port) and a **bridge-port**
(what the container connects to). By convention `bridge-port = chrome-port + 1`.

| Group | Chrome port | Bridge port |
|-------|-------------|-------------|
| meal-planner | 9222 | 9223 |
| nathan-barley | 9224 | 9225 |
| rs-assistant | 9226 | 9227 |
| rs-work-pa | 9228 | 9229 |

The ports are the single source of truth — they live in each group's
`container_configs.mcp_servers["chrome-devtools"].args` (`--browserUrl`) and
are read at runtime by `live-chrome.sh`, so the launcher and the container
always agree.

## Setup

Run once to install and enable the systemd services:

```bash
bash scripts/install-live-chrome-autostart.sh --start-now
```

This reads the DB to discover which groups have a `chrome-devtools` MCP with
a bridge URL, writes one `~/.config/systemd/user/nanoclaw-live-chrome-<group>.service`
per group (with `LIVE_CHROME_HEADLESS=1`), enables them for
`graphical-session.target`, and (with `--start-now`) starts them immediately.

## Signing in

The headless service has no visible window. To sign into sites, use the
**login script**, which stops the service, opens a headed browser window for
you to sign in, and then restarts the service automatically:

```bash
bash scripts/live-chrome-login.sh <group> [start-url]

# Examples:
bash scripts/live-chrome-login.sh rs-work-pa
bash scripts/live-chrome-login.sh rs-work-pa https://accounts.google.com
bash scripts/live-chrome-login.sh meal-planner https://www.tesco.com
```

Sign into whatever sites you need (approve 2FA, tick "Remember me"), then
close the browser window. The service restarts automatically and the agent
can use the new sessions immediately.

You can sign into as many sites as you like in the one session. Sessions
persist in the profile indefinitely — you only need to repeat this when a
site expires your session or you add a new one.

### Manual approach (equivalent to the login script)

```bash
systemctl --user stop nanoclaw-live-chrome-<group>.service
LIVE_CHROME_HEADLESS=0 bash scripts/live-chrome.sh <group>
# sign in, close the window
systemctl --user start nanoclaw-live-chrome-<group>.service
```

## Checking service status

```bash
systemctl --user status nanoclaw-live-chrome-rs-work-pa.service

# Check all live-browser services at once:
systemctl --user status 'nanoclaw-live-chrome-*.service'

# Check the bridge log for connection errors:
tail -f ~/.nanoclaw-live-chrome/rs-work-pa-bridge.log
```

## When the agent reports it can't connect

The agent will tell you to run `bash scripts/live-chrome-login.sh <group>` if:
- The session has expired and it landed on a login page.
- The bridge can't reach Chromium (e.g. service restarting).

The agent cannot fix this itself — sign-in requires a human in the loop.

## Adding a new live-browser group

1. Add the `chrome-devtools` MCP to the group's container config, picking the
   next available port pair. Example (adjust ports):

   ```bash
   ncl groups config update --id <group-id> --mcp-servers-merge '{
     "chrome-devtools": {
       "command": "chrome-devtools-mcp",
       "args": [
         "--browserUrl", "http://host.docker.internal:9231",
         "--no-usage-statistics",
         "--logFile", "/workspace/agent/chrome-devtools-mcp.log"
       ],
       "env": {
         "NO_PROXY": "host.docker.internal,localhost,127.0.0.1",
         "no_proxy": "host.docker.internal,localhost,127.0.0.1"
       }
     }
   }'
   ```

2. Re-run the installer to pick up the new group and install its service:
   ```bash
   bash scripts/install-live-chrome-autostart.sh --start-now
   ```

3. Sign in:
   ```bash
   bash scripts/live-chrome-login.sh <group-folder>
   ```

4. Add `instructions` to the MCP config explaining what sites the agent is
   signed into, and when to use this browser vs `agent-browser`.

## Why headless?

Chromium on Wayland (Hyprland, Arch Linux) silently skips the DevTools HTTP
server in headed (windowed) mode — the remote debugging port never binds, no
error is printed, and no `DevToolsActivePort` file is created. This has been
tested across multiple Chromium flag combinations (`--remote-debugging-address`,
`--no-sandbox`, `--disable-gpu`, `--enable-automation`, with/without
`--remote-allow-origins`, etc.) and is consistent across Chromium 148 on this
host. `--headless=new` binds the port immediately.

The trade-off is no visible window for the running service. The persistent
profile (cookies, localStorage, account sessions) is fully preserved in headless
mode — only the rendering surface differs. Sign-in is handled out-of-band via
the login script, which opens a standard headed Chromium window (without a debug
port) on the same profile.

## Files

| File | Purpose |
|------|---------|
| `scripts/live-chrome.sh` | Launches Chromium for a group. Headless (service) mode when `LIVE_CHROME_HEADLESS=1`; headed (login) mode otherwise |
| `scripts/live-chrome-login.sh` | Sign-in helper: stops service → headed browser → restart service |
| `scripts/chrome-devtools-bridge.mjs` | CDP proxy: rewrites Host header, forwards loopback traffic from container to Chromium |
| `scripts/install-live-chrome-autostart.sh` | Generates + enables systemd user services for all live-browser groups |
| `~/.nanoclaw-live-chrome/<group>/` | Persistent Chromium profile (cookies, sessions, downloads config) |
| `~/.config/systemd/user/nanoclaw-live-chrome-<group>.service` | Systemd user service unit |
| `groups/<group>/downloads/` | Default download directory for the group's browser (mounted at `/workspace/agent/downloads` in the container) |
