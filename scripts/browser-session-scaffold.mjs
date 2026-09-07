#!/usr/bin/env node
/**
 * browser-session-scaffold.mjs — After a session is captured, update the group's
 * session manifest and (re)write the per-group `browser-session` skill so the
 * agent knows which sessions exist and how to use them.
 *
 * Invoked by browser-session-export.sh via env vars:
 *   GROUP, NAME, LOGIN_URL, DEST (host path), MANIFEST (host path), SKILL_DIR
 *
 * The skill is idempotent: rewritten from the manifest on every export.
 */
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';

const { GROUP, NAME, LOGIN_URL, MANIFEST, SKILL_DIR } = process.env;
const CONTAINER_DIR = '/workspace/agent/.browser-sessions';

function loadManifest() {
  try {
    const data = JSON.parse(readFileSync(MANIFEST, 'utf8'));
    return Array.isArray(data.sessions) ? data.sessions : [];
  } catch {
    return [];
  }
}

const sessions = loadManifest().filter((s) => s.name !== NAME);
sessions.push({
  name: NAME,
  url: LOGIN_URL,
  file: `${CONTAINER_DIR}/${NAME}-exported-session.json`,
  exportedAt: new Date().toISOString(),
});
sessions.sort((a, b) => a.name.localeCompare(b.name));
writeFileSync(MANIFEST, JSON.stringify({ sessions }, null, 2));

const rows = sessions
  .map((s) => `| \`${s.name}\` | ${s.url} | \`${s.file}\` | ${s.exportedAt} |`)
  .join('\n');

const skill = `---
name: browser-session
description: Access websites the user has logged into for you via exported browser sessions (cookies + localStorage). Use whenever a task needs an authenticated website that has a saved session listed below — load the session, then browse with agent-browser.
allowed-tools: Bash(agent-browser:*)
metadata:
  type: integration
---

# Authenticated browsing with exported sessions

The user can log in to a website on their machine and export that session for
you. Each exported session is a Playwright \`storageState\` file (cookies +
localStorage) saved in this group's workspace. Load it into \`agent-browser\`
before visiting the site and you'll already be signed in — **never** ask for
credentials, and never try to log in yourself.

## Available sessions

| name | site | file | exported (UTC) |
|------|------|------|----------------|
${rows}

(Also machine-readable at \`${CONTAINER_DIR}/index.json\`.)

## How to use one

\`\`\`bash
# Load the saved session, then browse as the logged-in user.
agent-browser state load ${CONTAINER_DIR}/<name>-exported-session.json
agent-browser open <the site's page you need>
agent-browser snapshot -i
\`\`\`

Load the session **before** \`open\`. Use the \`file\` path from the table above.

## When the session has expired

Sessions expire (cookies/tokens rotate). If, after loading a session, you land
on a **login / sign-in / OTP / "verify it's you" page**, the session is stale.
Do **not** try to log in, solve a CAPTCHA, or ask for a password. Instead, stop
and tell the user, verbatim-ish:

> Your \`<name>\` session has expired. Please re-export it on your Mac:
> \`bash scripts/browser-session-export.sh ${GROUP} <name>\`

Then retry once they confirm.

## Guardrails

- These sessions act as the **real, logged-in user**. Reads are fine; before any
  irreversible or outward action (placing an order, sending a message, changing
  account settings, making a payment) show what you're about to do and confirm.
- Never print, echo, copy, or upload the contents of a session file — it holds
  live auth tokens.
- Some sites with strong bot detection (e.g. Tesco) will block this headless
  browser even with a valid session. If a site consistently blocks you despite a
  fresh session, tell the user — it likely needs the live-browser approach
  instead, not session export.
`;

mkdirSync(SKILL_DIR, { recursive: true });
writeFileSync(path.join(SKILL_DIR, 'SKILL.md'), skill);
console.error(`Updated skill + manifest (${sessions.length} session(s)).`);
