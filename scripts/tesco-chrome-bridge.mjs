#!/usr/bin/env node
/**
 * tesco-chrome-bridge — Host-header-rewriting reverse proxy for Chrome DevTools.
 *
 * Why this exists:
 *   meal-planner runs in a Docker container and drives a dedicated Chrome on
 *   this Mac (the one logged into Tesco) over the Chrome DevTools Protocol via
 *   `chrome-devtools-mcp --browser-url`. Two Chrome protections block the
 *   container from connecting directly to `host.docker.internal:9222`:
 *     1. Chrome binds --remote-debugging-port to 127.0.0.1 only. On Docker
 *        Desktop for Mac, container traffic to `host.docker.internal` IS
 *        delivered to the host loopback, so reachability is fine — but:
 *     2. Chrome's DNS-rebinding protection rejects any request whose `Host`
 *        header is a non-localhost hostname. The container sends
 *        `Host: host.docker.internal:9223`, which Chrome refuses.
 *
 *   This proxy listens on loopback only (127.0.0.1:9223), forwards to Chrome
 *   on 127.0.0.1:9222, and rewrites the `Host` header to a loopback literal
 *   Chrome accepts. It also rewrites the webSocketDebuggerUrl in /json
 *   responses back to the host:port the client used, so the CDP websocket
 *   connects back through the bridge rather than trying to reach Chrome
 *   directly.
 *
 * Security: loopback-bound. The dedicated Chrome profile holds ONLY the Tesco
 *   session, so even the open debug surface is contained to one grocery account.
 *
 * Usage:
 *   node scripts/tesco-chrome-bridge.mjs
 *   BRIDGE_PORT=9223 CHROME_PORT=9222 node scripts/tesco-chrome-bridge.mjs
 */
import http from 'node:http';
import net from 'node:net';

const LISTEN_HOST = process.env.BRIDGE_HOST || '127.0.0.1';
const LISTEN_PORT = Number(process.env.BRIDGE_PORT || 9223);
const TARGET_HOST = process.env.CHROME_HOST || '127.0.0.1';
const TARGET_PORT = Number(process.env.CHROME_PORT || 9222);
const TARGET_HOSTHDR = `${TARGET_HOST}:${TARGET_PORT}`;

function rewriteHeaders(headers) {
  // Force the Host header to a loopback literal Chrome's DNS-rebinding
  // protection accepts. Everything else is passed through untouched.
  return { ...headers, host: TARGET_HOSTHDR };
}

const server = http.createServer((req, res) => {
  const clientHost = req.headers.host; // e.g. host.docker.internal:9223
  const upstream = http.request(
    { host: TARGET_HOST, port: TARGET_PORT, method: req.method, path: req.url, headers: rewriteHeaders(req.headers) },
    (upRes) => {
      const ct = String(upRes.headers['content-type'] || '');
      // For the JSON discovery endpoints, buffer + rewrite ws URLs so the
      // client reconnects through this bridge. Everything else streams through.
      if (ct.includes('application/json') && clientHost) {
        const chunks = [];
        upRes.on('data', (c) => chunks.push(c));
        upRes.on('end', () => {
          let text = Buffer.concat(chunks).toString('utf8');
          text = text.split(TARGET_HOSTHDR).join(clientHost).split(`localhost:${TARGET_PORT}`).join(clientHost);
          const body = Buffer.from(text, 'utf8');
          const headers = { ...upRes.headers };
          delete headers['content-length'];
          res.writeHead(upRes.statusCode || 502, headers);
          res.end(body);
        });
      } else {
        res.writeHead(upRes.statusCode || 502, upRes.headers);
        upRes.pipe(res);
      }
    },
  );
  upstream.on('error', (err) => {
    res.writeHead(502, { 'content-type': 'text/plain' });
    res.end(`tesco-chrome-bridge upstream error: ${err.message}\n`);
  });
  req.pipe(upstream);
});

// WebSocket / CDP upgrade passthrough with Host rewrite. CDP is a plain HTTP
// Upgrade handshake followed by raw frames, so we splice the two sockets after
// replaying the handshake with the corrected Host header.
server.on('upgrade', (req, clientSocket, head) => {
  const upstream = net.connect(TARGET_PORT, TARGET_HOST, () => {
    const headers = rewriteHeaders(req.headers);
    let handshake = `${req.method} ${req.url} HTTP/1.1\r\n`;
    for (const [k, v] of Object.entries(headers)) {
      if (Array.isArray(v)) for (const vv of v) handshake += `${k}: ${vv}\r\n`;
      else handshake += `${k}: ${v}\r\n`;
    }
    handshake += '\r\n';
    upstream.write(handshake);
    if (head && head.length) upstream.write(head);
    upstream.pipe(clientSocket);
    clientSocket.pipe(upstream);
  });
  upstream.on('error', () => clientSocket.destroy());
  clientSocket.on('error', () => upstream.destroy());
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  console.log(`tesco-chrome-bridge: http://${LISTEN_HOST}:${LISTEN_PORT} -> Chrome ${TARGET_HOSTHDR}`);
});
