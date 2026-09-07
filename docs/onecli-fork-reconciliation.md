# OneCLI fork reconciliation — make the deployed gateway build from `PartridgeNet/onecli` main

**Status:** plan only. Not executed. Written 2026-08-19.

## Why this exists

The OneCLI gateway running on `nipogi-e3` (`onecli-fork:v1.39.0-ebay-trading`) was built
from a **local, non-git folder** `/home/rs/onecli-build`. The GitHub fork
`PartridgeNet/onecli` `main` is now the source of truth for the one PartridgeNet
customization (the eBay provider, commit `2fbf4f8`), but the fork has *also* moved
ahead of the deployed binary with upstream work the running gateway does not have.

So "what's on GitHub" ≠ "what's running." This plan closes that gap by rebuilding
and redeploying from a clean clone of the fork, and retiring `onecli-build` as the
build source.

**This is optional and not urgent.** Nothing is broken; the running gateway already
has every PartridgeNet change. Do this only when you want GitHub to be the literal,
reproducible build source. See [reference: onecli-gateway-deploy] for the deploy
recipe and the current-state facts this plan builds on.

## What the rebuild pulls in (the gap, fork-ahead-of-deployed)

Verified 2026-08-19 by diffing fork `main` against `onecli-build`. Three things, only
the first has teeth:

1. ⚠️ **`is_platform` column drop** — Prisma migration
   `20260628005429_drop_secret_is_platform` removes the `is_platform` boolean from the
   `secret` table. This is the **only destructive, irreversible-in-place** step and the
   entire reason this needs a plan rather than a blind rebuild.
2. **Edition → capability layer (#402)** — `packages/api/src/lib/edition.ts` +
   `apps/gateway/src/edition.rs`. Selects OSS vs Cloud behavior. Builds as **`oss`** by
   default (no `cloud` Cargo feature / `*_EDITION` env) → local auth, no billing,
   org-per-user. Matches the current `AUTH_MODE=local` setup. **Behavior-neutral for us.**
3. **`cache.ts` refactor + ~50 other files** — internal upstream evolution (e.g. the
   gateway CONNECT-cache invalidation moved from `gateway-cache.ts` to an edition-aware
   `cache.ts`). **Behavior-neutral for us.**

There is **no** fork-is-behind gap: `onecli-build` carried no local delta beyond eBay
(no PartridgeNet markers anywhere in its source; every build-only line was a superseded
older-upstream form). Nothing needs porting *up* before the rebuild.

## The core risk, stated plainly

Dropping a column is coupled to the new code: the new gateway expects `is_platform`
gone, the old gateway expects it present. You cannot cleanly run new code on the old
schema or old code on the new schema. Therefore:

- The migration will run as part of bringing up the new image.
- **Rollback after the migration has run requires restoring the database**, not just
  flipping the image tag back — because the old image's Prisma client still references
  the dropped column.

So the linchpin is a **verified, restorable database backup taken immediately before
cutover**. Everything else is ordinary deploy hygiene.

## Pre-flight (do all of this before touching production)

1. **Fresh clone as the new build source.** Replace the ad-hoc `onecli-build` folder
   with a real git checkout so future builds are reproducible and traceable:
   ```bash
   git clone git@github.com:PartridgeNet/onecli.git /home/rs/onecli-src
   cd /home/rs/onecli-src && git rev-parse HEAD   # record the commit you build from
   ```
   (Keep `onecli-build` untouched until the new deploy is verified — it's the fallback.)

2. **Confirm it builds as the OSS edition.** Ensure no `cloud` Cargo feature and no
   `*_EDITION=cloud` / `NEXT_PUBLIC_EDITION=cloud` env leaks into the build. The default
   is OSS; just verify nothing overrides it.

3. **Understand what the `is_platform` drop actually costs.** Find the real table/column
   and check whether any live data depends on it *before* you let the migration delete it:
   ```bash
   # exact table/column: Prisma model `secret`, column @map("is_platform")
   docker exec onecli-postgres-1 psql -U onecli -d onecli -c \
     "SELECT count(*) FILTER (WHERE is_platform) AS platform_secrets, count(*) AS total FROM secret;"
   ```
   - If `platform_secrets = 0`: the drop loses nothing meaningful. Low risk.
   - If `> 0`: stop and understand what that flag drives in the *new* code before
     proceeding — the column is going away, so any behavior keyed on it changes.

4. **Confirm how migrations get applied on container start.** Read the fork's
   `docker/entrypoint.sh` to see whether it runs `prisma migrate deploy` (applies pending
   migrations, expected) vs `prisma db push` (schema-force). Know exactly what will run,
   and confirm the DB user in the running compose stack has DDL rights (it does — it owns
   the schema).

5. **Take a verified DB backup.** This is the safety net the whole plan rests on.
   ```bash
   docker exec onecli-postgres-1 pg_dump -U onecli -Fc onecli \
     > /home/rs/onecli-db-backup-$(date +%Y%m%dT%H%M%SZ).dump
   # sanity: non-zero size, and pg_restore --list parses it
   pg_restore --list /home/rs/onecli-db-backup-*.dump | head
   ```
   Optionally also snapshot the `pgdata` docker volume for a belt-and-braces restore.

## Execution

6. **Build the new image from the clone**, pinning a descriptive tag (don't reuse
   `v1.39.0-ebay-trading` — the contents differ). Suggested scheme records the fork
   commit:
   ```bash
   cd /home/rs/onecli-src
   TAG="v1.39.0-main-$(git rev-parse --short HEAD)"
   docker build -f docker/Dockerfile --build-arg APP_VERSION="$TAG" -t onecli-fork:"$TAG" .
   ```
   Keep the current `onecli-fork:v1.39.0-ebay-trading` image — it's the code-rollback.

7. **Cut over** during a quiet window (there's a brief egress-proxy blip for agent
   containers). Back up the compose file, bump the tag, force-recreate only the app
   service:
   ```bash
   cp /home/rs/.onecli/docker-compose.yml /home/rs/.onecli/docker-compose.yml.bak-pre-main
   # set image: onecli-fork:<TAG> on the `onecli` service (postgres untouched)
   cd /home/rs/.onecli && docker compose -p onecli up -d --force-recreate onecli
   ```
   The migration runs here, on the new container's start.

## Verification (canaries)

8. Confirm health, version, edition, and that nothing regressed:
   ```bash
   curl -s http://100.71.226.93:10254/v1/health          # version == new TAG
   curl -s -o /dev/null -w '%{http_code}\n' http://100.71.226.93:10255/healthz   # 200
   docker exec onecli printenv GATEWAY_BASE_URL           # still 100.71.226.93:10255
   docker logs onecli 2>&1 | grep -i -E 'migrat|prisma'   # migration applied cleanly, no error
   ```
9. **Migration applied:** confirm the column is gone and no errors in logs:
   ```bash
   docker exec onecli-postgres-1 psql -U onecli -d onecli -c \
     "SELECT column_name FROM information_schema.columns WHERE table_name='secret' AND column_name='is_platform';"
   # expect zero rows
   ```
10. **Functional:** confirm auth still resolves as OSS/local, existing connections still
    inject (list an agent's secrets, exercise one connected app), and eBay still works —
    a REST call and, if reachable, a Trading-API (`/ws/api.dll`) call should both carry
    their headers.

## Rollback

- **Before the migration ran / it failed to start:** flip `image:` back to
  `onecli-fork:v1.39.0-ebay-trading` (or restore `docker-compose.yml.bak-pre-main`) and
  `docker compose -p onecli up -d --force-recreate onecli`. No DB action needed.
- **After the migration ran** (schema already changed) and you need the old code back:
  restore the DB backup *and* flip the image:
  ```bash
  cd /home/rs/.onecli && docker compose -p onecli stop onecli
  docker exec -i onecli-postgres-1 pg_restore -U onecli -d onecli --clean --if-exists \
    < /home/rs/onecli-db-backup-<stamp>.dump
  # restore old image tag in compose, then:
  docker compose -p onecli up -d --force-recreate onecli
  ```
  This is why the pre-cutover backup (step 5) is non-negotiable.

## After success

- Make `/home/rs/onecli-src` (the git clone) the canonical build source going forward;
  retire `/home/rs/onecli-build` once the new deploy is proven, so there's no ambiguity
  about where the running binary comes from.
- Update [reference: onecli-gateway-deploy] and `docs/onecli-remote-gateway.md` with the
  new build source path, image tag, and the fact that fork `main` == deployed again.
