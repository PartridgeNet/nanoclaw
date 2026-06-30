# ClassCharts Parent MCP Server — Implementation Spec

> Hand this to an agent working **in the same repo as the Grub MCP server**. Mirror Grub's
> conventions for the MCP transport, project layout, build, lint, tests, and deployment;
> this spec only describes what's *different* about ClassCharts plus the exact API behaviour
> it must implement. Where this spec and the Grub server's existing patterns disagree on
> style/structure, follow the Grub server.

## 1. Goal

A small **Streamable-HTTP MCP server** that exposes a UK school's **ClassCharts parent**
data (homework, behaviour, attendance, timetable, announcements, etc.) as MCP tools.

It is consumed by AI agents (the "NanoClaw" assistants). Agents reach it over Tailscale; an
upstream credential gateway (OneCLI) injects the ClassCharts login as an HTTP `Authorization`
header on every request. **The server holds no credentials at rest** — it receives them per
request, logs in to ClassCharts itself, and manages the (short-lived, rotating) session.

## 2. How it's invoked (the contract — do not change without coordinating)

```
agent (codex/claude) ──MCP/HTTP──► [OneCLI gateway injects Authorization: Basic base64(email:password)]
                                  ──► THIS SERVER (Tailscale IP : PORT, path /mcp)
                                  ──► logs in to ClassCharts, caches+pings session
                                  ──► https://www.classcharts.com/apiv2parent/*
```

- Transport: **Streamable HTTP MCP**, same as the Grub MCP server. Serve the MCP endpoint at
  `POST /mcp` (match Grub's exact path/handler; if Grub uses a different path, use the same).
- The server is reached at a **plain `http://<host>:<port>/mcp`** URL (TLS is terminated /
  MITM'd by the gateway upstream; do not require HTTPS on the listener). Bind to `0.0.0.0`
  so it's reachable on the Tailscale interface.
- Port and bind address must be **configurable via env** (e.g. `CLASSCHARTS_MCP_PORT`,
  default `4181` — pick a port that doesn't collide with Grub). Document the default.

### 2.1 Incoming auth header (how creds arrive)

Every MCP request arrives with a standard HTTP Basic header injected by the gateway:

```
Authorization: Basic <base64( email + ":" + password )>
```

The server MUST:
1. Read the `Authorization` header. If absent or not `Basic `, reject the MCP call with a
   clear error: *"Missing ClassCharts credentials — the OneCLI 'ClassCharts (Parent)' secret
   is not assigned to this agent."* (Do not 500; return an MCP tool error / JSON-RPC error.)
2. Base64-decode the value, split on the **first** `:` into `email` and `password`
   (passwords may contain `:`, so split once only).
3. Use those to obtain/refresh a ClassCharts session (see §4).

> **Security:** NEVER log the `Authorization` header, the decoded email/password, the
> derived ClassCharts `session_id`, or full request bodies. Redact them everywhere. The
> server stores creds only in memory for the lifetime of a cached session (§4), never on disk.

## 3. Dependencies

- **`classcharts-api`** (npm) — the maintained TypeScript wrapper. Source:
  https://github.com/classchartsapi/classcharts-api-js . Use `ParentClient`. Pin an exact
  version; verify the methods named in §5 exist in the version you pin (the API below matches
  the current `src/core/parentClient.ts` + `src/core/baseClient.ts`).
- The same MCP SDK the Grub server uses (`@modelcontextprotocol/sdk` or equivalent).

You MAY reimplement the thin HTTP calls directly instead of depending on `classcharts-api`
(the whole protocol is in §7), but using the library is recommended — it already handles the
302-cookie login and the ping/rotation logic.

## 4. Session management (the crux — ClassCharts sessions rotate every ~3 min)

ClassCharts auth is stateful and short-lived:

- Login returns a `session_id` (32-char hex).
- Authenticated requests send `Authorization: Basic <session_id>` (note: this is the
  *ClassCharts* session, distinct from the *incoming* Basic header that carries email:password).
- The `session_id` must be revalidated via `POST /apiv2parent/ping` (`include_data=true`)
  **before it is ~3 minutes old** (`PING_INTERVAL = 180_000 ms`). Each ping returns a **new**
  `session_id` that replaces the old one. A token left unpinged for >3 min is dead.

Requirements:

1. **Cache one ClassCharts session per credential set.** Key the cache by a hash of the
   incoming creds (e.g. `sha256(base64creds)`) so multiple agents sharing the same family
   login share one session. Value = the logged-in `ParentClient` (or your own session struct)
   plus `lastPing` timestamp.
2. **Keep-alive.** Before serving a tool call, if `now - lastPing > ~150_000 ms` (safety
   margin under 180s), call the ping/`getNewSessionId()` to refresh. (A background interval is
   also acceptable, but lazy-refresh-on-use is simpler and sufficient.)
3. **Re-login on failure.** If a ClassCharts request fails with an auth error (401/redirect to
   login / "No session ID" / "Unauthenticated"), discard the cached session, `login()` again
   once, and retry the request a single time. If re-login fails, return a clear tool error
   (likely bad/changed credentials).
4. **Serialize per session.** `ParentClient.selectPupil()` mutates shared state
   (`studentId`) on the client instance, and ping rotates the shared `session_id`. Guard each
   cached session with an **async mutex** so concurrent tool calls can't interleave a
   `selectPupil` / ping / fetch from different requests. (Per-session lock; different
   credential sets can run in parallel.)
5. **Idle eviction.** Optional: drop a cached session after, say, 30 min idle to avoid
   needless pings. On next use it logs in fresh.

## 5. Tools to expose

Use whatever tool-naming convention the Grub server uses; suggested names below. All "pupil"
data tools operate on one child; the account may have several children, so they take a
`pupil_id`. Resolve it as: if `pupil_id` omitted and exactly one pupil exists, use it;
otherwise require `pupil_id` and error listing valid ids/names if missing or unknown.

Internally each pupil tool does (inside the per-session lock): ensure session fresh →
`client.selectPupil(pupil_id)` → call the method → return `response.data`.

| Tool | Params | classcharts-api call | Notes |
|------|--------|----------------------|-------|
| `classcharts_get_pupils` | — | `getPupils()` | No pupil needed. Returns children with `id`, `name`, etc. Call this first to discover `pupil_id`s. |
| `classcharts_get_homework` | `pupil_id?`, `from?` (YYYY-MM-DD), `to?` (YYYY-MM-DD), `display_date?` (`"issue_date"`\|`"due_date"`, default `issue_date`) | `getHomeworks({ from, to, displayDate })` | |
| `classcharts_get_behaviour` | `pupil_id?`, `from?`, `to?` | `getBehaviour({ from, to })` | Positive + negative behaviour points. |
| `classcharts_get_activity` | `pupil_id?`, `from?`, `to?` | `getActivity({ from, to })` | Recent activity feed (single page). |
| `classcharts_get_full_activity` | `pupil_id?`, `from?`, `to?` | `getFullActivity({ from, to })` | Paginated full activity (library walks pages). Use when a full range is needed. |
| `classcharts_get_attendance` | `pupil_id?`, `from` (**required**), `to` (**required**) | `getAttendance({ from, to })` | from/to are required by the API. |
| `classcharts_get_timetable` | `pupil_id?`, `date` (**required**, YYYY-MM-DD) | `getLessons({ date })` | One day's lessons. |
| `classcharts_get_announcements` | `pupil_id?` | `getAnnouncements()` | School announcements. |
| `classcharts_get_badges` | `pupil_id?` | `getBadges()` | Award/event badges. |
| `classcharts_get_detentions` | `pupil_id?` | `getDetentions()` | |
| `classcharts_get_pupil_info` | `pupil_id?` | `getStudentInfo()` and/or `getPupilFields()` | Profile / custom fields. |

- Date params are strings in `YYYY-MM-DD`. Validate format and return a friendly error on bad
  input rather than passing junk upstream.
- Return the parsed `data` payload from each response as the tool result (JSON). Don't
  truncate — the agent needs the real data. Include the `meta` (e.g. pagination, date ranges)
  where the library surfaces it and it's useful.
- Tool descriptions should state these are **read-only**; this server must never perform
  writes (don't expose `changePassword`).

## 6. Exact ClassCharts protocol (so it can be implemented without the library if desired)

- **Base:** `BASE_URL = https://www.classcharts.com`; parent API base
  `API_BASE = https://www.classcharts.com/apiv2parent`.
- **Login:** `POST https://www.classcharts.com/parent/login`,
  `Content-Type: application/x-www-form-urlencoded`, `redirect: manual`. Body fields:
  `_method=POST`, `email=<email>`, `logintype=existing`, `password=<password>`,
  `recaptcha-token=no-token-available` (literal string — **no real reCAPTCHA is required**).
  Success = HTTP **302** with a `Set-Cookie`. Parse the `parent_session_credentials` cookie;
  its value is JSON `{ "session_id": "...", ... }`. That `session_id` is the bearer.
- **Authenticated request header:** `Authorization: Basic <session_id>` (the raw session_id,
  *not* base64 of anything).
- **Ping / refresh:** `POST {API_BASE}/ping` with body `include_data=true` and the auth
  header → response `meta.session_id` is the new token; store it and reset `lastPing`.
- **Data endpoints** (GET, with the auth header), where `<sid>` is the selected pupil/student id:
  - `GET {API_BASE}/pupils` → list of pupils (use a pupil `id` as `<sid>`)
  - `GET {API_BASE}/homeworks/<sid>?<params>`  (params: `from`, `to`, `display_date`)
  - `GET {API_BASE}/behaviour/<sid>?<params>` (`from`, `to`)
  - `GET {API_BASE}/activity/<sid>?<params>` (`from`, `to`)
  - `GET {API_BASE}/attendance/<sid>?<params>` (`from`, `to`)
  - `GET {API_BASE}/timetable/<sid>?date=<YYYY-MM-DD>`
  - `GET {API_BASE}/announcements/<sid>`
  - `GET {API_BASE}/eventbadges/<sid>`
  - `GET {API_BASE}/detentions/<sid>`
  - `GET {API_BASE}/customfields/<sid>`
  Send a browser-ish `user-agent` and `x-requested-with: XMLHttpRequest`; expect a JSON body
  `{ success, data, meta?, error? }`. `success !== 1` or a 302/redirect ⇒ treat as auth/permission failure.

## 7. Error handling

- Missing/invalid incoming `Authorization` → MCP tool error: credentials not assigned (see §2.1).
- ClassCharts login fails (no 302 / no cookie) → tool error: *"ClassCharts login failed —
  check the stored credentials."* Do not echo the creds.
- Unknown/missing `pupil_id` when multiple pupils → tool error listing valid `{id, name}`.
- Upstream 5xx / network → tool error with a short message; the agent will surface it.
- All errors must be returned as MCP tool/JSON-RPC errors with human-readable messages, never
  as raw stack traces or by leaking secrets.

## 8. Config & deployment

- Env: `CLASSCHARTS_MCP_PORT` (default `4181`), bind `0.0.0.0`. No credential env vars.
- Deploy the **same way Grub is deployed** in this repo (systemd unit / Docker / process
  manager — match Grub). It must run as a long-lived service so the session cache persists.
- **Deployment host:** the **same Debian server that hosts the Grub MCP server**
  (Tailscale `100.108.5.11`). Deploy alongside Grub using the same service mechanism. Pick a
  port that doesn't collide with Grub (Grub uses `4180`; default this server to `4181`). The
  NanoClaw side reaches it at `http://100.108.5.11:<port>/mcp` and sets the OneCLI secret's
  `hostPattern` to `100.108.5.11`. Ensure the box's firewall (e.g. `ufw`) allows inbound on
  the chosen port from the Tailnet, exactly as it already does for Grub's port.

## 9. Tests / acceptance

- Unit: Basic-header parse (incl. password containing `:`), missing-header rejection,
  date-format validation, pupil resolution (single vs multiple), the session refresh decision
  (`now - lastPing` threshold), and re-login-once-on-auth-failure.
- Mock the ClassCharts HTTP layer (don't hit the real API in CI; there's reCAPTCHA-free login
  but it's a real family account — keep it out of automated tests).
- Manual acceptance (operator, with a real session): from a machine on the Tailnet,
  `curl http://<host>:<port>/mcp` an MCP `tools/list` and a `classcharts_get_pupils` call with
  a real `Authorization: Basic base64(email:password)` header → expect the pupil list. Then a
  dated `classcharts_get_homework` → expect homework JSON. Confirm a second call >3 min later
  still works (proves the ping/refresh loop).

## 10. Out of scope

- No write operations. No credential storage. No direct exposure to the public internet
  (Tailnet only). No student-client support (parent only) unless the Grub repo owner wants it.
