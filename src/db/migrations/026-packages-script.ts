import type { Migration } from './index.js';

/**
 * `packages_script` on `container_configs`: an optional shell script that is
 * injected as a Dockerfile heredoc `RUN` command after the apt/npm layers
 * when building a per-group image. Intended for installs that can't be
 * satisfied by apt alone — e.g. compiling a specific language runtime version
 * from source.
 *
 * NOTE: `name` is 'packages-script' (NOT the filename number). This migration
 * was originally authored as `019-packages-script` and is already applied by
 * that name on the live DB; renumbered to 026 to sit past upstream's 025, but
 * the name is the dedup key and MUST NOT change or the runner re-runs it.
 */
export const migration026: Migration = {
  version: 26,
  name: 'packages-script',
  async up(db) {
    await db.exec(`ALTER TABLE container_configs ADD COLUMN packages_script TEXT;`);
  },
};
