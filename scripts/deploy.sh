#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — platform-infra production deploy
#
# Mirrors cue/scripts/deploy-hetzner.sh in shape: invoked by a GitHub Actions
# workflow over SSH, drives docker compose + terraform on the server.
#
# Required env vars:
#   APP_DIR     — absolute path to the platform-infra repo on the server
#   TARGET      — one of: DeployPlatformInfra | ForceRecreateAll |
#                 RestartService | ProvisionProject | BackupNow |
#                 CompleteRefresh
#   GIT_REF     — git branch / tag / SHA to deploy
#
# Optional env vars:
#   CONFIRM_DESTRUCTIVE   — "true" to allow CompleteRefresh (default: false)
#   FORCE_CLEAN_BUILD     — "true" to pass --no-cache to docker compose build
#                           (default: false on DeployPlatformInfra,
#                            implicitly true on ForceRecreateAll)
#   SERVICE_NAME          — required by RestartService (without platform- prefix
#                           OK, e.g. "redis" or "platform-redis")
#   PROJECT_NAME          — required by ProvisionProject (e.g. "cue")
#   WAIT_FOR_HEALTHY      — "true" to block until key services are healthy
#                           (default: true)
#   DEPLOY_ENV            — "production" → auto-decrypt .env.production.enc and
#                                          symlink .env → .env.production
#                           "development" → auto-decrypt .env.enc → .env
#                           unset (default) → backward-compat: require an
#                                          operator-placed cleartext .env
#
# Prerequisites on the server (already true on this prod box):
#   1. Repo cloned at APP_DIR with a populated .env at APP_DIR/.env
#   2. Docker + docker compose v2 installed
#   3. Data volumes already exist for DeployPlatformInfra/ForceRecreateAll
#      (the script hard-fails on these targets if volumes are missing, to
#       prevent an accidental fresh setup on a server that should have data)
# ─────────────────────────────────────────────────────────────────────────────

APP_DIR="${APP_DIR:?APP_DIR is required}"
TARGET="${TARGET:?TARGET is required}"
GIT_REF="${GIT_REF:?GIT_REF is required}"
CONFIRM_DESTRUCTIVE="${CONFIRM_DESTRUCTIVE:-false}"
FORCE_CLEAN_BUILD="${FORCE_CLEAN_BUILD:-false}"
SERVICE_NAME="${SERVICE_NAME:-}"
PROJECT_NAME="${PROJECT_NAME:-}"
WAIT_FOR_HEALTHY="${WAIT_FOR_HEALTHY:-true}"
DEPLOY_ENV="${DEPLOY_ENV:-}"

log_section() {
  echo "══════════════════════════════════════════════"
  echo " $1"
  echo "══════════════════════════════════════════════"
}

require_destructive_confirmation() {
  if [[ "$CONFIRM_DESTRUCTIVE" != "true" ]]; then
    echo "ERROR: $1 requires confirm_destructive_action=true"
    exit 1
  fi
}

ensure_env_file() {
  # When DEPLOY_ENV is unset, keep backward-compat behaviour: just require
  # that an operator-placed cleartext .env already exists.
  if [[ -z "$DEPLOY_ENV" ]]; then
    [[ -f "$APP_DIR/.env" ]] || {
      echo "ERROR: $APP_DIR/.env is missing and DEPLOY_ENV is unset."
      echo "       Either set DEPLOY_ENV=production|development to auto-decrypt,"
      echo "       or place a cleartext .env at $APP_DIR/.env."
      exit 1
    }
    return 0
  fi

  # DEPLOY_ENV is set → committed .enc is the source of truth, decrypt every
  # run so the box matches what's in git.
  cd "$APP_DIR"
  local enc plain
  case "$DEPLOY_ENV" in
    production)  enc=".env.production.enc"; plain=".env.production" ;;
    development) enc=".env.enc";             plain=".env" ;;
    *)
      echo "ERROR: DEPLOY_ENV must be 'production' or 'development' (got: '$DEPLOY_ENV')"
      exit 1
      ;;
  esac

  [[ -f "$enc" ]] || {
    echo "ERROR: $enc is missing — cannot auto-decrypt with DEPLOY_ENV=$DEPLOY_ENV"
    exit 1
  }
  [[ -f "keys/prod-age.txt" ]] || {
    echo "ERROR: keys/prod-age.txt is missing — needed to decrypt $enc"
    echo "       Restore from your password manager (SECRETS_RUNBOOK.md §7)."
    exit 1
  }
  export PATH="$HOME/.local/bin:$PATH"
  command -v sops >/dev/null || {
    echo "ERROR: sops not found on PATH. Run: make secrets-install"
    exit 1
  }

  log_section "Auto-decrypting $enc (DEPLOY_ENV=$DEPLOY_ENV)"
  bash scripts/setup-sops.sh decrypt "$enc"

  # Compose and the Makefile TF targets all read .env. On production we point
  # .env at the decrypted .env.production so nothing downstream needs to know
  # which environment it is.
  if [[ "$DEPLOY_ENV" == "production" ]]; then
    ln -sfn "$plain" .env
    echo "Linked .env → $plain"
  fi
}

pull_code() {
  log_section "Pulling $GIT_REF"
  cd "$APP_DIR"
  git fetch --all --tags --prune
  git reset --hard
  git -c advice.detachedHead=false checkout "$GIT_REF"
  git reset --hard "origin/$GIT_REF" 2>/dev/null || true
}

# Hard-fail if the named volume is missing on the host — guards against an
# accidental fresh-setup deploy nuking data on a server that should have it.
require_data_volumes_present() {
  log_section "Verifying data volumes exist (refusing to bootstrap on a prod box)"
  local missing=()
  local v
  for v in \
      platform_postgres_data \
      platform_keycloak_postgres_data \
      platform_redis_data \
      platform_minio_data; do
    if ! docker volume inspect "platform-infra_${v}" >/dev/null 2>&1 \
        && ! docker volume inspect "${v}" >/dev/null 2>&1; then
      missing+=("$v")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: expected data volumes are missing: ${missing[*]}"
    echo "       This server looks empty. Refusing to deploy."
    echo "       If this is genuinely a fresh server, run CompleteRefresh with"
    echo "       confirm_destructive_action=true instead."
    exit 1
  fi
  echo " all expected volumes present"
}

# docker compose v2 needs the project name to find platform-infra_default
# when reading from the directory's compose file. We don't override; we rely
# on the directory basename (platform-infra) becoming the project name.
compose() {
  cd "$APP_DIR"
  docker compose "$@"
}

build_images() {
  log_section "Building locally-built images (postgres, keycloak-postgres, alertmanager, backup, mcp)"
  local args=()
  if [[ "$FORCE_CLEAN_BUILD" == "true" ]]; then
    args+=(--no-cache)
  fi
  compose build "${args[@]}"
}

start_services_smart() {
  log_section "Starting services (only changed containers recreate)"
  # No --force-recreate: compose recreates only services whose image or
  # config changed. Postgres/Redis/MinIO containers stay up unless their
  # image (built locally) was rebuilt this run.
  compose up -d --remove-orphans
}

start_services_force() {
  log_section "Force-recreating all services"
  compose up -d --force-recreate --remove-orphans
}

restart_one_service() {
  local svc="$SERVICE_NAME"
  [[ -n "$svc" ]] || {
    echo "ERROR: RestartService requires service_name input"
    exit 1
  }
  # Accept either bare ("redis") or full ("platform-redis") names.
  if [[ "$svc" != platform-* && "$svc" != postgres-exporter-* \
        && "$svc" != "redis-exporter" && "$svc" != "cadvisor" ]]; then
    svc="platform-$svc"
  fi
  log_section "Restarting single service: $svc"
  # Quick sanity check that the service exists in compose.
  if ! compose config --services | grep -qx "$svc"; then
    echo "ERROR: '$svc' is not a service in docker-compose.yml"
    echo "Available services:"
    compose config --services | sed 's/^/  /'
    exit 1
  fi
  compose up -d --force-recreate --no-deps "$svc"
}

wait_for_health() {
  [[ "$WAIT_FOR_HEALTHY" == "true" ]] || return 0
  log_section "Waiting for core services to be healthy (up to 120 s)"
  local attempt=0
  local svc cid health all_healthy
  local svcs=(platform-postgres platform-keycloak-postgres platform-keycloak platform-redis platform-minio)
  while true; do
    all_healthy=true
    for svc in "${svcs[@]}"; do
      cid=$(docker ps -q --filter "name=^${svc}$" 2>/dev/null || true)
      if [[ -z "$cid" ]]; then
        all_healthy=false
        echo "  $svc: not running"
        continue
      fi
      health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo "unknown")
      if [[ "$health" == "healthy" || "$health" == "none" ]]; then
        :  # healthy or has no healthcheck defined
      else
        all_healthy=false
        echo "  $svc: $health"
      fi
    done
    if [[ "$all_healthy" == "true" ]]; then
      echo " all core services healthy"
      break
    fi
    attempt=$((attempt + 1))
    if [[ $attempt -ge 24 ]]; then
      echo "ERROR: not all services became healthy after 120 s"
      compose ps
      exit 1
    fi
    echo "  Waiting... ($((attempt * 5)) s elapsed)"
    sleep 5
  done
}

provision_project() {
  [[ -n "$PROJECT_NAME" ]] || {
    echo "ERROR: ProvisionProject requires project_name input"
    exit 1
  }
  log_section "Provisioning project: $PROJECT_NAME (terraform apply -target)"
  cd "$APP_DIR"
  # `make provision` runs `terraform init && terraform apply -target=module.<p>`.
  # It's idempotent — already-existing DB/realm/bucket resources are no-ops.
  make provision PROJECT="$PROJECT_NAME"
}

backup_now() {
  log_section "Running on-demand backups (pg_dump + wal-g base backups)"
  cd "$APP_DIR"
  # Logical dump of all platform DBs → MinIO platform-backups bucket.
  make backup-now
  # Base backups for PITR (wal segments stream continuously via archive_command).
  make wal-base-backup
  make wal-base-backup-keycloak
  echo ""
  log_section "Backup catalog"
  make backup-list || true
  make wal-list || true
}

show_status() {
  echo ""
  log_section "Platform service status"
  compose ps
}

prune_old_images() {
  docker image prune -f --filter "until=24h" >/dev/null || true
}

# ── Bootstrap ──────────────────────────────────────────────────────────────────

# Pull first so the latest .env.production.enc (and the script itself) is on
# disk before we decrypt. Otherwise an updated .enc from this push would be
# read on the NEXT deploy, not this one.
pull_code
ensure_env_file

# ── Deployment targets ────────────────────────────────────────────────────────

case "$TARGET" in

  # ── Default safe deploy ─────────────────────────────────────────────────────
  # Builds locally-built images (cache-respecting) and runs `up -d` without
  # --force-recreate. Containers whose image or config changed are recreated;
  # others are untouched. This is the workhorse target.
  DeployPlatformInfra)
    require_data_volumes_present
    build_images
    start_services_smart
    wait_for_health
    ;;

  # ── Force-recreate every container ──────────────────────────────────────────
  # Use after a wal-g binary upgrade, base-image bump, or anything else that
  # needs every container restarted. Causes ~30-60s of unavailability for
  # Postgres/Keycloak. Implies --no-cache build.
  ForceRecreateAll)
    require_data_volumes_present
    FORCE_CLEAN_BUILD=true
    build_images
    start_services_force
    wait_for_health
    ;;

  # ── Restart a single named service ──────────────────────────────────────────
  # For surgical ops: e.g. RestartService SERVICE_NAME=prometheus after
  # editing rules, or platform-mcp after a code change.
  RestartService)
    require_data_volumes_present
    restart_one_service
    ;;

  # ── Terraform-provision a project namespace ─────────────────────────────────
  # Idempotent — creates the per-project DB role, Keycloak realm, MinIO bucket,
  # and LiteLLM virtual key if missing. Run with PROJECT_NAME=cue.
  ProvisionProject)
    require_data_volumes_present
    provision_project
    ;;

  # ── On-demand snapshot (pg_dump + wal-g base) ───────────────────────────────
  # Safe, non-disruptive. Run before risky changes to give yourself a clean
  # restore point on top of the 03:00 UTC nightly + continuous WAL.
  BackupNow)
    require_data_volumes_present
    backup_now
    ;;

  # ── Wipe and rebuild from scratch (most destructive) ────────────────────────
  # Treats the server as fresh. NUKES every named volume — postgres, keycloak,
  # redis, minio (incl. terraform state bucket and platform-backups bucket).
  # Then rebuilds images, brings up a clean stack, re-bootstraps the MinIO TF
  # state bucket, and runs `terraform apply` against ALL project modules.
  #
  # Use only on a new app with no data worth keeping, or as an explicit reset.
  # Downstream apps (e.g. Cue) WILL break — their DB roles, Keycloak realms,
  # MinIO buckets, and LiteLLM keys are recreated, so they must be restarted
  # and re-run their own schema migrations.
  CompleteRefresh)
    require_destructive_confirmation "CompleteRefresh"
    log_section "WIPING all platform-infra volumes (containers + data)"
    cd "$APP_DIR"
    docker compose down -v --remove-orphans
    FORCE_CLEAN_BUILD=true
    build_images
    start_services_force
    wait_for_health
    log_section "Re-bootstrapping Terraform state bucket in MinIO"
    cd "$APP_DIR"
    make tf-bootstrap
    log_section "Initialising Terraform against the fresh MinIO backend"
    make tf-init-remote
    log_section "Applying Terraform (provisions every project module)"
    make tf-apply-all
    ;;

  *)
    echo "ERROR: Unknown deployment target '$TARGET'"
    echo "       Valid targets: DeployPlatformInfra | ForceRecreateAll |"
    echo "                      RestartService | ProvisionProject |"
    echo "                      BackupNow | CompleteRefresh"
    exit 1
    ;;
esac

show_status
prune_old_images

echo ""
echo "✓ Deployment complete  •  target: $TARGET  •  ref: $GIT_REF"
