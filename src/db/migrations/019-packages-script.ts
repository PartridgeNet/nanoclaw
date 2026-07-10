import type { Migration } from './index.js';

/**
 * `packages_script` on `container_configs`: an optional shell script that is
 * injected as a Dockerfile heredoc `RUN` command after the apt/npm layers
 * when building a per-group image. Intended for installs that can't be
 * satisfied by apt alone — e.g. compiling a specific language runtime version
 * from source.
 */
export const migration019: Migration = {
  version: 19,
  name: 'packages-script',
  up(db) {
    db.exec(`ALTER TABLE container_configs ADD COLUMN packages_script TEXT;`);
  },
};
