/**
 * Host-side container config for the `pi` provider.
 *
 * The `pi` provider (container/agent-runner/src/providers/pi.ts) runs the Pi
 * agent harness in-process against an OpenAI-compatible gateway. Unlike
 * OpenCode it needs no `serve` subprocess and no XDG project dir — only the
 * PI_* runtime settings, read on the host and injected into the container when
 * the effective provider is `pi`.
 *
 * The values come from `.env` (the service units set no EnvironmentFile, so
 * ctx.hostEnv carries none of these under systemd/launchd — fall back to the
 * file the way the claude/opencode providers do; a real exported variable still
 * wins over the file).
 */
import { readEnvFile } from '../env.js';
import { registerProviderContainerConfig } from './provider-container-registry.js';

const PASSTHROUGH_KEYS = [
  'PI_BASE_URL',
  'PI_MODEL',
  'PI_CONTEXT_WINDOW',
  'PI_MAX_TOKENS',
  'PI_API_KEY',
  'PI_THINKING_FORMAT',
] as const;

registerProviderContainerConfig('pi', (ctx) => {
  const env: Record<string, string> = {};
  const dotenv = readEnvFile([...PASSTHROUGH_KEYS]);
  for (const key of PASSTHROUGH_KEYS) {
    const value = ctx.hostEnv[key] ?? dotenv[key];
    if (value) env[key] = value;
  }
  return { env };
});
