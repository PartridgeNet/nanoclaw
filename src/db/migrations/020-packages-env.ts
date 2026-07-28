import type { Migration } from './index.js';

/**
 * `packages_env` on `container_configs`: a JSON `Record<string, string>` of
 * environment variables to emit as Dockerfile `ENV` instructions in the
 * per-group image build. Required for tooling (e.g. Android SDK, custom
 * language runtimes) whose PATH and env vars must be visible to the agent
 * process at runtime — a `packages_script` RUN block can install the files
 * but can't persist env vars across layers without explicit ENV instructions.
 */
export const migration020: Migration = {
  version: 20,
  name: 'packages-env',
  up(db) {
    db.exec(`ALTER TABLE container_configs ADD COLUMN packages_env TEXT NOT NULL DEFAULT '{}';`);
  },
};
