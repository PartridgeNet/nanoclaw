# Host redeploy script

Use this after a merge lands on `main` and the live NanoClaw install needs to pull, rebuild, and restart. Run it from the live checkout — the folder with `data/`, `groups/`, and `logs/`.

```bash
pnpm run deploy:host
```

`deploy:host` performs the manual redeploy sequence:

1. verifies the checkout is live and has no tracked local edits,
2. backs up `data/`, `groups/`, and env files to `.nanoclaw/backups/`,
3. fetches and fast-forwards `origin/main`,
4. installs host and agent-runner dependencies,
5. builds the host TypeScript and typechecks the agent runner,
6. rebuilds the agent container image with `./container/build.sh`,
7. stamps `data/upgrade-state.json`,
8. restarts the host service with `setup/lib/restart.sh`, and
9. runs light `ncl` smoke checks.

For future upstream merges, merge the PR first, then run the script on the host. If this is the first time the script is being introduced into an existing install, pull once to get the script, then run it:

```bash
git fetch origin --prune
git checkout main
git pull --ff-only origin main
pnpm run deploy:host
```

Useful options:

```bash
pnpm run deploy:host -- --skip-pull        # rebuild/restart current checkout
pnpm run deploy:host -- --skip-restart     # prepare only
pnpm run deploy:host -- --skip-smoke       # skip post-restart ncl checks
pnpm run deploy:host -- --via post-pr-123  # label the upgrade marker
```

If the script stops before the restart, fix the reported issue and rerun it. Do not manually stamp the upgrade marker unless the install/build/container rebuild steps actually succeeded.
