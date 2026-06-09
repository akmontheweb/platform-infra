#!/usr/bin/env bash
# =============================================================================
# backup.sh — dump every platform DB to MinIO via mc pipe.
#
# Streams each pg_dump straight into MinIO so nothing touches local disk.
# Naming: s3://${BACKUP_BUCKET}/postgres/{server}/{db}/{ts}.dump
# Retention: enforced by the MinIO bucket lifecycle rule (set up by entrypoint).
#
# Triggered by crond per services/backup/crontab. Also runnable on-demand:
#   docker compose exec platform-backup /opt/backup/backup.sh
# =============================================================================
set -euo pipefail

ts="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
bucket="${BACKUP_BUCKET:-platform-backups}"
alias="platform"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { log "ERROR: $*"; exit 1; }

# Tuples of "server|db|user|password_env". Hostnames resolve on the
# platform-infra_default network.
backups=(
  "platform-postgres|cue|${PLATFORM_PG_SUPERUSER}|PLATFORM_PG_SUPERPASSWORD"
  "platform-postgres|litellm|${PLATFORM_PG_SUPERUSER}|PLATFORM_PG_SUPERPASSWORD"
  "platform-keycloak-postgres|keycloak|${PLATFORM_KC_DB_USER}|PLATFORM_KC_DB_PASSWORD"
)

# Pre-flight: MinIO + every PG server must respond before we start so a partial
# run can't leave the bucket inconsistent.
mc ready "${alias}" >/dev/null 2>&1 || fail "MinIO alias '${alias}' not reachable"

failures=0
for spec in "${backups[@]}"; do
  IFS='|' read -r host db user pwvar <<<"${spec}"
  pw="${!pwvar:-}"
  if [[ -z "${pw}" ]]; then
    log "skip ${host}/${db}: env ${pwvar} empty"
    failures=$((failures + 1))
    continue
  fi

  obj="postgres/${host}/${db}/${ts}.dump"
  log "dump ${host}/${db} → s3://${bucket}/${obj}"

  # pg_dump -Fc: custom format (compressed, restorable with pg_restore).
  # mc pipe streams stdin to the object with no local disk I/O.
  # Both sides have to succeed; pipefail propagates pg_dump failures.
  if ! PGPASSWORD="${pw}" pg_dump \
        --host="${host}" \
        --username="${user}" \
        --dbname="${db}" \
        --format=custom \
        --no-owner \
        --no-acl \
        --compress=9 \
        --verbose 2>/tmp/pg_dump.${db}.log \
        | mc pipe "${alias}/${bucket}/${obj}" >/dev/null
  then
    log "FAIL ${host}/${db}: $(tail -3 /tmp/pg_dump.${db}.log)"
    failures=$((failures + 1))
    continue
  fi

  size="$(mc stat --json "${alias}/${bucket}/${obj}" 2>/dev/null | grep -o '"size":[0-9]*' | head -1 | cut -d: -f2 || echo 0)"
  log "OK   ${host}/${db}  ${size} bytes"
done

if (( failures > 0 )); then
  fail "${failures} backup(s) failed; check logs above"
fi

log "all backups OK (${#backups[@]} dumps to s3://${bucket}/)"
