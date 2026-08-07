/**
 * Authenticated HTTP channel for first-party mobile clients.
 *
 * The client discovers the owner's current agent groups at runtime. Access is
 * therefore bounded by possession of a paired device credential rather than a
 * second, inevitably stale list of agent ids in the APK.
 */
import crypto from 'crypto';
import type http from 'http';

import { readEnvFile } from '../env.js';
import { getDb } from '../db/connection.js';
import { getAgentGroup, getAllAgentGroups } from '../db/agent-groups.js';
import { wakeContainer } from '../container-runner.js';
import { resolveSession, writeSessionMessage } from '../session-manager.js';
import { registerWebhookHandler } from '../webhook-server.js';
import type { Session } from '../types.js';
import type { ChannelAdapter, ChannelSetup, OutboundMessage } from './adapter.js';
import { registerChannelAdapter } from './channel-registry.js';

const CHANNEL_TYPE = 'mobile';
const MAX_BODY_BYTES = 16 * 1024;
const MAX_PROMPT_CHARS = 2_000;
const ACCESS_TOKEN_TTL_MS = 15 * 60 * 1000;

interface DeviceRow {
  id: string;
  name: string;
  revoked_at: string | null;
}

const now = () => new Date().toISOString();
const hash = (value: string) => crypto.createHash('sha256').update(value).digest('hex');
const opaqueToken = () => crypto.randomBytes(32).toString('base64url');

function json(res: http.ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Cache-Control': 'no-store',
  });
  res.end(JSON.stringify(body));
}

async function readJson(req: http.IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += bytes.length;
    if (size > MAX_BODY_BYTES) throw new Error('body_too_large');
    chunks.push(bytes);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8')) as Record<string, unknown>;
  } catch {
    throw new Error('invalid_json');
  }
}

function safeEqual(left: string, right: string): boolean {
  const a = Buffer.from(left);
  const b = Buffer.from(right);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function issueAccessToken(deviceId: string): { accessToken: string; expiresAt: string } {
  const accessToken = opaqueToken();
  const createdAt = now();
  const expiresAt = new Date(Date.now() + ACCESS_TOKEN_TTL_MS).toISOString();
  const db = getDb();
  db.prepare('DELETE FROM mobile_access_tokens WHERE expires_at <= ?').run(createdAt);
  db.prepare(
    'INSERT INTO mobile_access_tokens (token_hash, device_id, expires_at, created_at) VALUES (?, ?, ?, ?)',
  ).run(hash(accessToken), deviceId, expiresAt, createdAt);
  return { accessToken, expiresAt };
}

function authenticate(req: http.IncomingMessage): DeviceRow | null {
  const value = req.headers.authorization;
  if (!value?.startsWith('Bearer ')) return null;
  const device = getDb()
    .prepare(
      `SELECT d.id, d.name, d.revoked_at
         FROM mobile_access_tokens t
         JOIN mobile_devices d ON d.id = t.device_id
        WHERE t.token_hash = ? AND t.expires_at > ? AND d.revoked_at IS NULL`,
    )
    .get(hash(value.slice(7)), now()) as DeviceRow | undefined;
  if (device) getDb().prepare('UPDATE mobile_devices SET last_seen_at = ? WHERE id = ?').run(now(), device.id);
  return device ?? null;
}

function parseMobileAddress(platformId: string): { deviceId: string; agentGroupId: string } {
  const split = platformId.indexOf('|');
  if (split < 1) throw new Error('Invalid mobile delivery address');
  return { deviceId: platformId.slice(0, split), agentGroupId: platformId.slice(split + 1) };
}

function ensureConversation(deviceId: string, agentGroupId: string): Session {
  const db = getDb();
  const digest = hash(`${deviceId}:${agentGroupId}`).slice(0, 24);
  const messagingGroupId = `mg-mobile-${digest}`;
  const createdAt = now();
  db.prepare(
    `INSERT OR IGNORE INTO messaging_groups
       (id, channel_type, platform_id, instance, name, is_group, unknown_sender_policy, denied_at, created_at)
     VALUES (?, 'mobile', ?, 'mobile', ?, 0, 'strict', NULL, ?)`,
  ).run(messagingGroupId, `${deviceId}|${agentGroupId}`, `NanoClaw Chat: ${agentGroupId}`, createdAt);
  return resolveSession(agentGroupId, messagingGroupId, null, 'shared').session;
}

async function pair(body: Record<string, unknown>, res: http.ServerResponse): Promise<void> {
  const configured = readEnvFile(['NANOCLAW_MOBILE_PAIRING_CODE']).NANOCLAW_MOBILE_PAIRING_CODE;
  const supplied = typeof body.pairingCode === 'string' ? body.pairingCode : '';
  if (!configured || !safeEqual(configured, supplied)) {
    json(res, 401, { error: 'invalid_pairing_code' });
    return;
  }
  const deviceName = typeof body.deviceName === 'string' ? body.deviceName.trim().slice(0, 80) : '';
  if (!deviceName) {
    json(res, 400, { error: 'device_name_required' });
    return;
  }
  const deviceId = crypto.randomUUID();
  const refreshToken = opaqueToken();
  const timestamp = now();
  getDb()
    .prepare(
      `INSERT INTO mobile_devices (id, name, refresh_hash, revoked_at, created_at, last_seen_at)
       VALUES (?, ?, ?, NULL, ?, ?)`,
    )
    .run(deviceId, deviceName, hash(refreshToken), timestamp, timestamp);
  json(res, 201, { deviceId, refreshToken, ...issueAccessToken(deviceId) });
}

async function refresh(body: Record<string, unknown>, res: http.ServerResponse): Promise<void> {
  const refreshToken = typeof body.refreshToken === 'string' ? body.refreshToken : '';
  const device = getDb()
    .prepare('SELECT id, name, revoked_at FROM mobile_devices WHERE refresh_hash = ? AND revoked_at IS NULL')
    .get(hash(refreshToken)) as DeviceRow | undefined;
  if (!device) {
    json(res, 401, { error: 'invalid_refresh_token' });
    return;
  }
  const replacement = opaqueToken();
  getDb()
    .prepare('UPDATE mobile_devices SET refresh_hash = ?, last_seen_at = ? WHERE id = ?')
    .run(hash(replacement), now(), device.id);
  json(res, 200, { deviceId: device.id, refreshToken: replacement, ...issueAccessToken(device.id) });
}

async function sendMessage(device: DeviceRow, body: Record<string, unknown>, res: http.ServerResponse): Promise<void> {
  const agentGroupId = typeof body.agentGroupId === 'string' ? body.agentGroupId : '';
  const clientMessageId = typeof body.clientMessageId === 'string' ? body.clientMessageId : '';
  const text = typeof body.text === 'string' ? body.text.trim() : '';
  if (!getAgentGroup(agentGroupId)) {
    json(res, 404, { error: 'agent_not_found' });
    return;
  }
  if (!clientMessageId || clientMessageId.length > 128) {
    json(res, 400, { error: 'invalid_client_message_id' });
    return;
  }
  if (!text || text.length > MAX_PROMPT_CHARS) {
    json(res, 400, { error: 'invalid_prompt', maxChars: MAX_PROMPT_CHARS });
    return;
  }
  const existing = getDb()
    .prepare(
      `SELECT client_message_id AS clientMessageId, agent_group_id AS agentGroupId,
              session_id AS sessionId, accepted_at AS acceptedAt
         FROM mobile_message_receipts WHERE device_id = ? AND client_message_id = ?`,
    )
    .get(device.id, clientMessageId);
  if (existing) {
    json(res, 200, { ...existing, duplicate: true });
    return;
  }

  const session = ensureConversation(device.id, agentGroupId);
  const acceptedAt = now();
  getDb()
    .prepare(
      `INSERT INTO mobile_message_receipts
         (device_id, client_message_id, agent_group_id, session_id, accepted_at)
       VALUES (?, ?, ?, ?, ?)`,
    )
    .run(device.id, clientMessageId, agentGroupId, session.id, acceptedAt);
  writeSessionMessage(agentGroupId, session.id, {
    id: `mobile-${clientMessageId}`,
    kind: 'chat',
    timestamp: acceptedAt,
    platformId: `${device.id}|${agentGroupId}`,
    channelType: CHANNEL_TYPE,
    content: JSON.stringify({
      text,
      sender: device.name,
      senderId: `mobile:${device.id}`,
      clientMessageId,
      surface: 'android_auto',
      driving: true,
      responseStyle: 'concise speech-friendly plain text',
    }),
  });
  void wakeContainer(session);
  json(res, 202, { clientMessageId, agentGroupId, sessionId: session.id, acceptedAt, duplicate: false });
}

async function handleRequest(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
  const url = new URL(req.url ?? '/', 'http://localhost');
  try {
    if (req.method === 'POST' && url.pathname === '/webhook/mobile/pair') {
      await pair(await readJson(req), res);
      return;
    }
    if (req.method === 'POST' && url.pathname === '/webhook/mobile/token') {
      await refresh(await readJson(req), res);
      return;
    }
    const device = authenticate(req);
    if (!device) {
      json(res, 401, { error: 'authentication_required' });
      return;
    }
    if (req.method === 'GET' && url.pathname === '/webhook/mobile/agents') {
      json(res, 200, {
        agents: getAllAgentGroups().map(({ id, name }) => ({ id, name })),
      });
      return;
    }
    if (req.method === 'POST' && url.pathname === '/webhook/mobile/messages') {
      await sendMessage(device, await readJson(req), res);
      return;
    }
    if (req.method === 'GET' && url.pathname === '/webhook/mobile/events') {
      const after = Math.max(0, Number.parseInt(url.searchParams.get('after') ?? '0', 10) || 0);
      const events = getDb()
        .prepare(
          `SELECT seq, id, agent_group_id AS agentGroupId, kind, content,
                  sender_name AS senderName, created_at AS createdAt, read_at AS readAt
             FROM mobile_events WHERE device_id = ? AND seq > ? ORDER BY seq LIMIT 100`,
        )
        .all(device.id, after);
      json(res, 200, { events });
      return;
    }
    const readMatch = url.pathname.match(/^\/webhook\/mobile\/events\/([^/]+)\/read$/);
    if (req.method === 'POST' && readMatch) {
      const result = getDb()
        .prepare('UPDATE mobile_events SET read_at = COALESCE(read_at, ?) WHERE id = ? AND device_id = ?')
        .run(now(), decodeURIComponent(readMatch[1]!), device.id);
      json(res, result.changes ? 200 : 404, result.changes ? { ok: true } : { error: 'event_not_found' });
      return;
    }
    if (req.method === 'DELETE' && url.pathname === '/webhook/mobile/device') {
      getDb().prepare('UPDATE mobile_devices SET revoked_at = ? WHERE id = ?').run(now(), device.id);
      getDb().prepare('DELETE FROM mobile_access_tokens WHERE device_id = ?').run(device.id);
      json(res, 200, { ok: true });
      return;
    }
    json(res, 404, { error: 'not_found' });
  } catch (error) {
    const code = error instanceof Error ? error.message : 'invalid_request';
    json(res, code === 'body_too_large' ? 413 : 400, { error: code });
  }
}

class MobileChannelAdapter implements ChannelAdapter {
  readonly name = 'NanoClaw Mobile';
  readonly channelType = CHANNEL_TYPE;
  readonly supportsThreads = false;
  private connected = false;

  async setup(_config: ChannelSetup): Promise<void> {
    registerWebhookHandler(CHANNEL_TYPE, handleRequest);
    this.connected = true;
  }

  async teardown(): Promise<void> {
    this.connected = false;
  }

  isConnected(): boolean {
    return this.connected;
  }

  async deliver(platformId: string, _threadId: string | null, message: OutboundMessage): Promise<string> {
    const { deviceId, agentGroupId } = parseMobileAddress(platformId);
    const eventId = crypto.randomUUID();
    getDb()
      .prepare(
        `INSERT INTO mobile_events
           (id, device_id, agent_group_id, kind, content, sender_name, created_at, read_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, NULL)`,
      )
      .run(
        eventId,
        deviceId,
        agentGroupId,
        message.kind,
        JSON.stringify(message.content),
        message.senderName ?? null,
        now(),
      );
    return eventId;
  }
}

registerChannelAdapter(CHANNEL_TYPE, {
  factory: () => new MobileChannelAdapter(),
  defaults: {
    dm: { engageMode: 'pattern', engagePattern: '.', threads: false, unknownSenderPolicy: 'strict' },
    group: { engageMode: 'pattern', engagePattern: '.', threads: false, unknownSenderPolicy: 'strict' },
    mentions: 'dm-only',
  },
});

export const mobileChannelInternals = {
  hash,
  parseMobileAddress,
  safeEqual,
  MAX_PROMPT_CHARS,
};
