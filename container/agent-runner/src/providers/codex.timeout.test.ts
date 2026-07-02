import { describe, expect, it } from 'bun:test';

import { buildTurnTimeoutMessage } from './codex.js';

describe('buildTurnTimeoutMessage', () => {
  it('reports partial progress and appends a continue note when the agent had said something', () => {
    const msg = buildTurnTimeoutMessage(25 * 60 * 1000, '  Deployed the backend, checking healthz...  ');
    expect(msg).toContain('Deployed the backend, checking healthz...');
    // Partial text is preserved verbatim (trimmed) ahead of the note.
    expect(msg.startsWith('Deployed the backend, checking healthz...')).toBe(true);
    expect(msg).toContain('25-minute per-turn limit');
    expect(msg).toContain('ask me to continue');
  });

  it('explains the timeout and how to recover when there is no partial output', () => {
    const msg = buildTurnTimeoutMessage(25 * 60 * 1000, '   ');
    expect(msg).toContain('25-minute per-turn limit');
    expect(msg).toContain('too long for a single turn');
    expect(msg).toContain('CI build');
  });

  it('derives the minute count from the timeout value', () => {
    expect(buildTurnTimeoutMessage(10 * 60 * 1000, '')).toContain('10-minute');
    expect(buildTurnTimeoutMessage(90 * 1000, '')).toContain('2-minute');
  });
});
