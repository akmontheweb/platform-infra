#!/usr/bin/env bash
# =============================================================================
# base-backup.sh — fired weekly by cron inside the platform-postgres image.
#
# 1. Sources /etc/wal-g.env (cron strips env, so this is where wal-g's
#    S3 prefix + AWS creds + PGDATA come from).
# 2. Runs `wal-g backup-push $PGDATA` to take a full base backup against
#    the running cluster.
# 3. Runs `wal-g delete retain FULL 4 --confirm` so retention stays at
#    the last 4 weeks of base backups (~28 days). WAL between the oldest
#    base backup and now is preserved automatically by wal-g delete.
#
# Manual invocation (e.g. before a risky migration):
#   docker compose exec platform-postgres /opt/wal-g/base-backup.sh
# =============================================================================
set -euo pipefail

LOG=/var/log/wal-g.log
log() { printf '[wal-g %s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "${LOG}"; }
fail() { log "ERROR: $*"; exit 1; }

if [[ ! -r /etc/wal-g.env ]]; then
  fail "/etc/wal-g.env missing or unreadable; entrypoint must run before this script"
fi
# shellcheck disable=SC1091
. /etc/wal-g.env

: "${WALG_S3_PREFIX:?WALG_S3_PREFIX must be set in /etc/wal-g.env}"
: "${PGDATA:?PGDATA must be set}"

log "wal-g backup-push ${PGDATA} → ${WALG_S3_PREFIX}"
if ! wal-g backup-push "${PGDATA}" >> "${LOG}" 2>&1; then
  fail "wal-g backup-push failed; see ${LOG}"
fi

# Retain the last 4 full base backups. wal-g auto-trims orphaned WAL
# segments older than the oldest retained backup.
log "wal-g delete retain FULL 4 --confirm"
if ! wal-g delete retain FULL 4 --confirm >> "${LOG}" 2>&1; then
  # Retention failure is non-fatal — base backup already succeeded.
  log "WARN: retention sweep failed; backup itself succeeded"
fi

log "base-backup OK"
