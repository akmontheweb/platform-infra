#!/usr/bin/env bash
# =============================================================================
# entrypoint.sh — one-time MinIO bootstrap, then start crond.
#
#   1. Register the MinIO alias from PLATFORM_MINIO_ROOT_* env.
#   2. Create the backup bucket if it doesn't exist.
#   3. Apply a 7-day expiry lifecycle rule on the bucket (idempotent).
#   4. Run an initial backup so a fresh stack has something to restore from.
#   5. exec crond in the foreground.
# =============================================================================
set -euo pipefail

log() { printf '[entrypoint %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

: "${PLATFORM_MINIO_ROOT_USER:?PLATFORM_MINIO_ROOT_USER required}"
: "${PLATFORM_MINIO_ROOT_PASSWORD:?PLATFORM_MINIO_ROOT_PASSWORD required}"
: "${PLATFORM_PG_SUPERUSER:?PLATFORM_PG_SUPERUSER required}"
: "${PLATFORM_PG_SUPERPASSWORD:?PLATFORM_PG_SUPERPASSWORD required}"
: "${PLATFORM_KC_DB_USER:?PLATFORM_KC_DB_USER required}"
: "${PLATFORM_KC_DB_PASSWORD:?PLATFORM_KC_DB_PASSWORD required}"

bucket="${BACKUP_BUCKET:-platform-backups}"
retention_days="${BACKUP_RETENTION_DAYS:-7}"
minio_url="${MINIO_URL:-http://platform-minio:9000}"

log "registering mc alias 'platform' → ${minio_url}"
mc alias set platform "${minio_url}" \
  "${PLATFORM_MINIO_ROOT_USER}" "${PLATFORM_MINIO_ROOT_PASSWORD}" >/dev/null

# mc mb is idempotent with --ignore-existing.
log "ensuring bucket ${bucket} exists"
mc mb --ignore-existing "platform/${bucket}" >/dev/null

# Apply 7-day expiry on the postgres/ prefix. Idempotent: re-running with the
# same rule is a no-op.
log "ensuring ${retention_days}-day expiry rule on platform/${bucket}/postgres/"
mc ilm rule add \
  --expire-days "${retention_days}" \
  --prefix "postgres/" \
  "platform/${bucket}" >/dev/null 2>&1 || true

# Export the rotated credentials into root's crond environment. Alpine's crond
# does NOT inherit the parent process env, so we have to write them somewhere
# the cron-fired backup.sh will source.
log "exporting env to /etc/backup.env for cron"
{
  echo "export PLATFORM_PG_SUPERUSER='${PLATFORM_PG_SUPERUSER}'"
  echo "export PLATFORM_PG_SUPERPASSWORD='${PLATFORM_PG_SUPERPASSWORD}'"
  echo "export PLATFORM_KC_DB_USER='${PLATFORM_KC_DB_USER}'"
  echo "export PLATFORM_KC_DB_PASSWORD='${PLATFORM_KC_DB_PASSWORD}'"
  echo "export PLATFORM_MINIO_ROOT_USER='${PLATFORM_MINIO_ROOT_USER}'"
  echo "export PLATFORM_MINIO_ROOT_PASSWORD='${PLATFORM_MINIO_ROOT_PASSWORD}'"
  echo "export BACKUP_BUCKET='${bucket}'"
  echo "export MINIO_URL='${minio_url}'"
} > /etc/backup.env
chmod 600 /etc/backup.env

if [[ "${BACKUP_RUN_ON_START:-true}" == "true" ]]; then
  log "running initial backup so a fresh stack has something to restore from"
  /opt/backup/backup.sh || log "initial backup failed (non-fatal at boot — cron will retry)"
fi

log "starting crond (foreground)"
exec crond -f -d 8
