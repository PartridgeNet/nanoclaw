#!/usr/bin/env bash
# Pull the live NanoClaw checkout to main, rebuild the host + agent image,
# stamp the upgrade marker, restart the service, and run light smoke checks.
#
# Intended use from the live install folder after an upstream/fork merge lands:
#   pnpm run deploy:host

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

REMOTE="${NANOCLAW_DEPLOY_REMOTE:-origin}"
BRANCH="${NANOCLAW_DEPLOY_BRANCH:-main}"
VIA="${NANOCLAW_DEPLOY_VIA:-host-redeploy}"
BACKUP_ROOT="${NANOCLAW_BACKUP_DIR:-$PROJECT_ROOT/.nanoclaw/backups}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"

ALLOW_DIRTY=false
ALLOW_NON_LIVE=false
SKIP_BACKUP=false
SKIP_PULL=false
SKIP_CONTAINER_BUILD=false
SKIP_RESTART=false
SKIP_SMOKE=false

usage() {
  cat <<USAGE
Usage: pnpm run deploy:host -- [options]

Pull and redeploy the live NanoClaw checkout.

Options:
  --remote <name>             Git remote to fetch/pull (default: $REMOTE)
  --branch <name>             Branch to deploy (default: $BRANCH)
  --via <label>               upgrade-state marker label (default: $VIA)
  --backup-dir <path>         Backup directory (default: $BACKUP_ROOT)
  --allow-dirty               Continue even if tracked files have local changes
  --allow-non-live            Continue even if data/ or groups/ is missing
  --skip-backup               Do not archive data/, groups/, and env files
  --skip-pull                 Build/restart the current checkout without pulling
  --skip-container-build      Do not rebuild the agent container image
  --skip-restart              Do not restart the NanoClaw service
  --skip-smoke                Do not run ncl smoke checks after restart
  -h, --help                  Show this help

Environment overrides:
  NANOCLAW_DEPLOY_REMOTE, NANOCLAW_DEPLOY_BRANCH, NANOCLAW_DEPLOY_VIA,
  NANOCLAW_BACKUP_DIR, CONTAINER_RUNTIME
USAGE
}

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)
      [[ $# -ge 2 ]] || die "--remote requires a value"
      REMOTE="$2"
      shift 2
      ;;
    --branch)
      [[ $# -ge 2 ]] || die "--branch requires a value"
      BRANCH="$2"
      shift 2
      ;;
    --via)
      [[ $# -ge 2 ]] || die "--via requires a value"
      VIA="$2"
      shift 2
      ;;
    --backup-dir)
      [[ $# -ge 2 ]] || die "--backup-dir requires a value"
      BACKUP_ROOT="$2"
      shift 2
      ;;
    --allow-dirty)
      ALLOW_DIRTY=true
      shift
      ;;
    --allow-non-live)
      ALLOW_NON_LIVE=true
      shift
      ;;
    --skip-backup)
      SKIP_BACKUP=true
      shift
      ;;
    --skip-pull)
      SKIP_PULL=true
      shift
      ;;
    --skip-container-build)
      SKIP_CONTAINER_BUILD=true
      shift
      ;;
    --skip-restart)
      SKIP_RESTART=true
      shift
      ;;
    --skip-smoke)
      SKIP_SMOKE=true
      shift
      ;;
    --)
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

need git
need node
need pnpm
need bun

if [[ "$SKIP_BACKUP" != true ]]; then
  need tar
fi

if [[ "$SKIP_CONTAINER_BUILD" != true ]]; then
  need "$CONTAINER_RUNTIME"
  log "Checking $CONTAINER_RUNTIME access"
  "$CONTAINER_RUNTIME" info >/dev/null
fi

if [[ ! -f package.json || ! -d scripts || ! -f setup/lib/restart.sh || ! -f container/build.sh ]]; then
  die "run this from a NanoClaw checkout"
fi

if [[ "$ALLOW_NON_LIVE" != true && ( ! -d data || ! -d groups ) ]]; then
  die "this does not look like the live install (missing data/ or groups/); run from the host checkout or pass --allow-non-live"
fi

if [[ "$ALLOW_DIRTY" != true ]]; then
  dirty_status="$(git status --porcelain --untracked-files=no)"
  if [[ -n "$dirty_status" ]]; then
    printf '%s\n' "$dirty_status" >&2
    die "tracked files have local changes; commit/stash them or pass --allow-dirty"
  fi
fi

on_error() {
  local status=$?
  if [[ $status -ne 0 ]]; then
    warn "deploy failed with exit code $status"
    if [[ -f logs/nanoclaw.error.log ]]; then
      warn "last NanoClaw errors:"
      tail -n 80 logs/nanoclaw.error.log >&2 || true
    fi
  fi
}
trap on_error EXIT

stamp="$(date +%Y%m%d-%H%M%S)"

if [[ "$SKIP_BACKUP" != true ]]; then
  log "Creating backup"
  mkdir -p "$BACKUP_ROOT"
  backup_file="$BACKUP_ROOT/host-redeploy-$stamp.tgz"
  backup_items=()
  for item in data groups .env .env.local; do
    [[ -e "$item" ]] && backup_items+=("$item")
  done
  if [[ ${#backup_items[@]} -gt 0 ]]; then
    tar \
      --exclude='data/ncl.sock' \
      --exclude='data/cli.sock' \
      --exclude='data/v2-sessions/*/inbound.db-shm' \
      --exclude='data/v2-sessions/*/inbound.db-wal' \
      --exclude='data/v2-sessions/*/outbound.db-shm' \
      --exclude='data/v2-sessions/*/outbound.db-wal' \
      -czf "$backup_file" "${backup_items[@]}"
    printf 'Backup: %s\n' "$backup_file"
  else
    warn "no data/groups/env files found to back up"
  fi

  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    backup_branch="backup/host-redeploy-$stamp"
    git branch "$backup_branch" HEAD
    printf 'Backup branch: %s\n' "$backup_branch"
  fi
fi

if [[ "$SKIP_PULL" != true ]]; then
  log "Pulling $REMOTE/$BRANCH"
  git fetch "$REMOTE" --prune
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git checkout "$BRANCH"
  else
    git checkout -B "$BRANCH" "$REMOTE/$BRANCH"
  fi
  git pull --ff-only "$REMOTE" "$BRANCH"
fi

log "Current version"
printf 'Commit: %s\n' "$(git rev-parse --short HEAD)"
printf 'Version: %s\n' "$(node -p "require('./package.json').version")"

log "Installing dependencies"
pnpm install --frozen-lockfile
(
  cd container/agent-runner
  bun install --frozen-lockfile
)

log "Building host"
pnpm run build

log "Typechecking agent runner"
(
  cd container/agent-runner
  bun run typecheck
)

if [[ "$SKIP_CONTAINER_BUILD" != true ]]; then
  log "Building agent container image"
  ./container/build.sh
fi

log "Stamping upgrade marker"
pnpm exec tsx scripts/upgrade-state.ts set "" "$VIA"

if [[ "$SKIP_RESTART" != true ]]; then
  log "Restarting NanoClaw service"
  bash setup/lib/restart.sh
fi

if [[ "$SKIP_SMOKE" != true ]]; then
  log "Running smoke checks"
  if command -v ncl >/dev/null 2>&1; then
    ncl groups list >/dev/null
    ncl tasks list >/dev/null
  else
    pnpm run ncl -- groups list >/dev/null
    pnpm run ncl -- tasks list >/dev/null
  fi
fi

log "Redeploy complete"
printf 'Commit: %s\n' "$(git rev-parse --short HEAD)"
printf 'Version: %s\n' "$(node -p "require('./package.json').version")"
