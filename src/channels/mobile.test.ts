import { describe, expect, it } from 'vitest';

import { mobileChannelInternals } from './mobile.js';

describe('mobile channel security helpers', () => {
  it('hashes credentials without retaining their plaintext value', () => {
    const digest = mobileChannelInternals.hash('secret');
    expect(digest).toHaveLength(64);
    expect(digest).not.toContain('secret');
  });

  it('compares pairing codes without accepting prefixes', () => {
    expect(mobileChannelInternals.safeEqual('pairing-code', 'pairing-code')).toBe(true);
    expect(mobileChannelInternals.safeEqual('pairing-code', 'pairing')).toBe(false);
  });

  it('round trips the device and agent delivery address', () => {
    expect(mobileChannelInternals.parseMobileAddress('device-1|agent-2')).toEqual({
      deviceId: 'device-1',
      agentGroupId: 'agent-2',
    });
  });
});
