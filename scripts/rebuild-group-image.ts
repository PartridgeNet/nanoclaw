/**
 * Rebuild the per-group Docker image for a given agent group ID.
 * Usage: pnpm exec tsx scripts/rebuild-group-image.ts <agentGroupId>
 */
import path from 'path';
import { initDb } from '../src/db/connection.js';
import { buildAgentGroupImage } from '../src/container-runner.js';
import { DATA_DIR } from '../src/config.js';

const agentGroupId = process.argv[2];
if (!agentGroupId) {
  console.error('Usage: pnpm exec tsx scripts/rebuild-group-image.ts <agentGroupId>');
  process.exit(1);
}

initDb(path.join(DATA_DIR, 'v2.db'));
console.log(`Building image for ${agentGroupId}...`);
await buildAgentGroupImage(agentGroupId);
console.log('Done.');
