import type { Migration } from './index.js';

/**
 * Mobile channel transport tables (PartridgeNet fork, #6): device registry,
 * per-device access tokens, message-receipt idempotency, and an outbound event
 * queue for the authenticated mobile channel adapter.
 *
 * NOTE: `name` is 'mobile-channel' — already applied under that name on the
 * live DB (authored as `021-mobile-channel`); renumbered to 028, name unchanged.
 */
export const migration028: Migration = {
  version: 28,
  name: 'mobile-channel',
  async up(db) {
    await db.exec(`
      CREATE TABLE mobile_devices (
        id           TEXT PRIMARY KEY,
        name         TEXT NOT NULL,
        refresh_hash TEXT NOT NULL UNIQUE,
        revoked_at   TEXT,
        created_at   TEXT NOT NULL,
        last_seen_at TEXT NOT NULL
      );

      CREATE TABLE mobile_access_tokens (
        token_hash TEXT PRIMARY KEY,
        device_id  TEXT NOT NULL REFERENCES mobile_devices(id) ON DELETE CASCADE,
        expires_at TEXT NOT NULL,
        created_at TEXT NOT NULL
      );
      CREATE INDEX idx_mobile_access_device ON mobile_access_tokens(device_id);

      CREATE TABLE mobile_message_receipts (
        device_id        TEXT NOT NULL REFERENCES mobile_devices(id) ON DELETE CASCADE,
        client_message_id TEXT NOT NULL,
        agent_group_id    TEXT NOT NULL REFERENCES agent_groups(id) ON DELETE CASCADE,
        session_id        TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        accepted_at       TEXT NOT NULL,
        PRIMARY KEY (device_id, client_message_id)
      );

      CREATE TABLE mobile_events (
        seq            INTEGER PRIMARY KEY AUTOINCREMENT,
        id             TEXT NOT NULL UNIQUE,
        device_id      TEXT NOT NULL REFERENCES mobile_devices(id) ON DELETE CASCADE,
        agent_group_id TEXT NOT NULL REFERENCES agent_groups(id) ON DELETE CASCADE,
        kind           TEXT NOT NULL,
        content        TEXT NOT NULL,
        sender_name    TEXT,
        created_at     TEXT NOT NULL,
        read_at        TEXT
      );
      CREATE INDEX idx_mobile_events_device_seq ON mobile_events(device_id, seq);
    `);
  },
};
