#!/usr/bin/env node
/**
 * browser-session-export.mjs — Capture a logged-in browser session from a
 * running Chrome (DevTools Protocol) into a Playwright-format storageState JSON.
 *
 * This is the capture half of the "log in on the host, export the session for
 * the agent to use" workflow. scripts/browser-session-export.sh launches a real
 * Google Chrome (headed, isolated profile, loopback DevTools port); the user
 * logs in; then this helper connects over CDP and writes cookies + localStorage
 * in exactly the shape `agent-browser state load` (and Playwright) consume:
 *
 *   { "cookies": [ { name, value, domain, path, expires, httpOnly, secure, sameSite } ],
 *     "origins": [ { "origin": "...", "localStorage": [ { name, value } ] } ] }
 *
 * Zero dependencies: uses Node 22's global WebSocket + fetch. No Playwright, no
 * browser download — it drives the Chrome the user already logged into, so the
 * captured session matches that browser's fingerprint.
 *
 * Usage:
 *   node scripts/browser-session-export.mjs --port 9222 --out /path/session.json
 */
import { writeFileSync, chmodSync } from 'node:fs';

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const PORT = Number(arg('port', '9222'));
const HOST = arg('host', '127.0.0.1');
const OUT = arg('out');
if (!OUT) {
  console.error('browser-session-export: --out <file> is required');
  process.exit(2);
}

const BASE = `http://${HOST}:${PORT}`;

/** Minimal CDP client over a single WebSocket with id/response correlation. */
function connect(wsUrl) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    const pending = new Map();
    let nextId = 1;
    const timer = setTimeout(() => reject(new Error(`CDP connect timeout: ${wsUrl}`)), 10000);
    ws.addEventListener('open', () => {
      clearTimeout(timer);
      resolve({
        send(method, params = {}) {
          const id = nextId++;
          return new Promise((res, rej) => {
            pending.set(id, { res, rej });
            ws.send(JSON.stringify({ id, method, params }));
            setTimeout(() => {
              if (pending.has(id)) {
                pending.delete(id);
                rej(new Error(`CDP timeout: ${method}`));
              }
            }, 15000);
          });
        },
        close() {
          try { ws.close(); } catch { /* ignore */ }
        },
      });
    });
    ws.addEventListener('message', (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }
      if (msg.id && pending.has(msg.id)) {
        const { res, rej } = pending.get(msg.id);
        pending.delete(msg.id);
        if (msg.error) rej(new Error(msg.error.message || 'CDP error'));
        else res(msg.result);
      }
    });
    ws.addEventListener('error', () => reject(new Error(`CDP socket error: ${wsUrl}`)));
  });
}

/** Map a CDP cookie to Playwright's storageState cookie shape. */
function mapCookie(c) {
  const sameSite = ['Strict', 'Lax', 'None'].includes(c.sameSite) ? c.sameSite : 'Lax';
  return {
    name: c.name,
    value: c.value,
    domain: c.domain,
    path: c.path || '/',
    // Playwright uses seconds; -1 means a session cookie.
    expires: c.session || typeof c.expires !== 'number' || c.expires < 0 ? -1 : Math.round(c.expires),
    httpOnly: Boolean(c.httpOnly),
    secure: Boolean(c.secure),
    sameSite,
  };
}

async function main() {
  // 1. Browser-level endpoint (cookies live here, across all tabs).
  const version = await (await fetch(`${BASE}/json/version`)).json();
  const browser = await connect(version.webSocketDebuggerUrl);
  const { cookies: rawCookies } = await browser.send('Storage.getCookies');
  const cookies = (rawCookies || []).map(mapCookie);

  // 2. Per-page localStorage. Each open http(s) tab exposes its own WS target.
  const targets = await (await fetch(`${BASE}/json`)).json();
  const pages = (targets || []).filter(
    (t) => t.type === 'page' && /^https?:/.test(t.url || '') && t.webSocketDebuggerUrl,
  );

  const originMap = new Map(); // origin -> [{name, value}]
  for (const page of pages) {
    try {
      const client = await connect(page.webSocketDebuggerUrl);
      const { result } = await client.send('Runtime.evaluate', {
        returnByValue: true,
        expression:
          'JSON.stringify({origin: location.origin, ls: Object.entries(localStorage)})',
      });
      client.close();
      if (result && result.value) {
        const { origin, ls } = JSON.parse(result.value);
        if (origin && /^https?:/.test(origin)) {
          const entries = (ls || []).map(([name, value]) => ({ name, value }));
          const existing = originMap.get(origin) || [];
          // Merge (later tabs of the same origin win per key).
          const byName = new Map(existing.map((e) => [e.name, e]));
          for (const e of entries) byName.set(e.name, e);
          originMap.set(origin, [...byName.values()]);
        }
      }
    } catch (err) {
      console.error(`  (skipped a tab: ${err.message})`);
    }
  }
  browser.close();

  const origins = [...originMap.entries()].map(([origin, localStorage]) => ({
    origin,
    localStorage,
  }));

  const state = { cookies, origins };
  writeFileSync(OUT, JSON.stringify(state, null, 2));
  chmodSync(OUT, 0o600);

  const originList = origins.map((o) => o.origin).join(', ') || '(none)';
  console.error(
    `Captured ${cookies.length} cookies, localStorage for: ${originList}`,
  );
}

main().catch((err) => {
  console.error(`browser-session-export failed: ${err.message}`);
  process.exit(1);
});
