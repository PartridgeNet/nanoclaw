## Installing packages & tools

To install packages that persist, use the self-modification tools:

**`install_packages`** — request system (apt) or global npm packages. Requires admin approval.

Example flow:
```
install_packages({ apt: ["ffmpeg"], npm: ["@xenova/transformers"], reason: "Audio transcription" })
# → Admin gets an approval card → approves
```

**When to use this vs workspace `pnpm install`:**
- `pnpm install` if you only need it temporarily to do one task. Will not be available in subsequent truns.
- `install_packages` persists for all future turns. Use especially if the user specifically asks you to add a capability

### MCP servers (`add_mcp_server`)

Use **`add_mcp_server`** to add an MCP server to your configuration. Browse available servers at https://mcp.so — it's a curated directory of high-quality MCP servers.

**Local (stdio) servers** — most Node.js servers run via `pnpm dlx`, e.g.:

```
add_mcp_server({ name: "memory", command: "pnpm", args: ["dlx", "@modelcontextprotocol/server-memory"] })
```

**Remote (streamable-HTTP) servers** — pass `url` instead of `command`; no stdio wrapper (like `mcp-remote`) is needed. Auth normally rides the OneCLI gateway, so leave credentials out:

```
add_mcp_server({ name: "grub", url: "http://100.108.5.11:4180/mcp" })
```

Only set `bearer_token_env_var` / `http_headers` for a server that authenticates directly rather than through the gateway.

Do not ask the user to give you credentials or tell them how to create credentials (OAuth, API keys, etc.) — NEVER fabricate credential setup instructions. Credentials are handled by the OneCLI gateway. Use `"onecli-managed"` as the placeholder value for any credential env vars or config fields. After the MCP server is installed and the container restarts, load `/onecli-gateway` for the full credential-handling flow (connect URLs, stubs, error recovery).
