#!/usr/bin/env bash
# =============================================================================
# scripts/restore-drill.sh — cold-restore the latest dump for a DB into a
# scratch Postgres container and report row counts of a few canonical tables.
#
# Usage:
#   bash scripts/restore-drill.sh                    # default: cue DB
#   bash scripts/restore-drill.sh keycloak           # restore keycloak DB
#   bash scripts/restore-drill.sh litellm            # restore litellm DB
#   bash scripts/restore-drill.sh cue 2026-06-09T03  # specific snapshot prefix
#
# What it does:
#   1. Resolves the latest dump in s3://platform-backups/postgres/<srv>/<db>/
#      (or one matching the optional date prefix).
#   2. Spins up a temporary postgres:16-alpine container on the platform
#      network, no volume — pure ephemeral.
#   3. Streams the dump from MinIO via mc into pg_restore on the scratch DB.
#   4. Runs a SELECT count(*) on a small canonical set of tables.
#   5. Tears the scratch container down.
#
# Exit 0 = restore landed and row counts non-null.
# Exit non-zero = restore failed OR a sentinel table missing.
# =============================================================================
set -euo pipefail

db="${1:-cue}"
prefix_filter="${2:-}"

case "${db}" in
  cue)      server="platform-postgres"          ;;
  litellm)  server="platform-postgres"          ;;
  keycloak) server="platform-keycloak-postgres" ;;
  *) echo "unknown db: ${db} (expected cue|litellm|keycloak)" >&2; exit 2 ;;
esac

bucket="${BACKUP_BUCKET:-platform-backups}"
prefix="postgres/${server}/${db}/"
scratch="restore-drill-${db}-$$"

log() { printf '[restore-drill %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
cleanup() {
  log "cleanup: docker rm -f ${scratch}"
  docker rm -f "${scratch}" >/dev/null 2>&1 || true
  rm -f "/tmp/${scratch}.dump"
}
trap cleanup EXIT

# Resolve the latest object matching the prefix filter (optional).
log "looking up latest dump under s3://${bucket}/${prefix}${prefix_filter}"
latest_obj=$(
  docker compose exec -T platform-backup \
    mc ls --json "platform/${bucket}/${prefix}" 2>/dev/null \
    | grep "\"${prefix_filter}" \
    | grep '"type":"file"' \
    | grep -o '"key":"[^"]*"' \
    | sed 's/"key":"//; s/"$//' \
    | sort \
    | tail -1 \
    || true
)
if [[ -z "${latest_obj}" ]]; then
  log "FAIL: no dumps found under platform/${bucket}/${prefix}${prefix_filter}*"
  exit 1
fi
log "latest = ${latest_obj}"

# Pull the dump locally so we can pipe it into pg_restore without juggling
# two compose-exec sessions.
log "streaming dump to /tmp/${scratch}.dump"
docker compose exec -T platform-backup \
  mc cat "platform/${bucket}/${prefix}${latest_obj}" > "/tmp/${scratch}.dump"

# Stand up an ephemeral postgres on the same network so pg_restore can talk
# to itself by container_name. No volume → cleanup removes everything.
log "starting scratch postgres container ${scratch}"
docker run -d --rm \
  --name "${scratch}" \
  --network platform-infra_default \
  -e POSTGRES_PASSWORD=drill \
  -e POSTGRES_USER=drill \
  -e POSTGRES_DB=drill \
  postgres:16-alpine >/dev/null

# Wait for pg_isready (Postgres takes ~3-5s to be ready inside a fresh container).
for i in 1 2 3 4 5 6 7 8 9 10; do
  if docker exec "${scratch}" pg_isready -U drill -d drill >/dev/null 2>&1; then
    break
  fi
  sleep 1
  if [[ ${i} -eq 10 ]]; then
    log "FAIL: scratch postgres never became ready"
    exit 1
  fi
done

# Create the target DB matching the source name (so pg_restore object refs
# resolve in their expected schema/database).
docker exec "${scratch}" psql -U drill -d drill -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE ${db};" >/dev/null

# Pipe the dump from the host into pg_restore in the scratch container.
log "pg_restore --dbname=${db} -j 2 (verbose log → /tmp/${scratch}.log)"
if ! docker exec -i "${scratch}" pg_restore \
      --username=drill \
      --dbname="${db}" \
      --no-owner \
      --no-acl \
      --jobs=2 \
      --verbose \
      < "/tmp/${scratch}.dump" \
      > "/tmp/${scratch}.log" 2>&1; then
  log "pg_restore exited non-zero — first 20 lines of error log:"
  head -20 "/tmp/${scratch}.log"
  log "FAIL"
  exit 1
fi

# Canonical row-count probes per DB. Pick tables that should always be
# non-empty in a real deployment.
case "${db}" in
  cue)
    probes=(users tasks audit_logs error_codes)
    ;;
  litellm)
    probes=("LiteLLM_VerificationToken" "LiteLLM_UserTable")
    ;;
  keycloak)
    probes=(realm user_entity client)
    ;;
esac

log "probing row counts in restored ${db}:"
all_ok=1
for tbl in "${probes[@]}"; do
  if cnt=$(docker exec "${scratch}" psql -U drill -d "${db}" \
              -tAc "SELECT count(*) FROM \"${tbl}\";" 2>/dev/null); then
    printf '  %-32s %s rows\n' "${tbl}" "${cnt}"
  else
    printf '  %-32s MISSING\n' "${tbl}"
    all_ok=0
  fi
done

if (( all_ok == 1 )); then
  log "OK — restore drill for ${db} passed"
  exit 0
else
  log "FAIL — one or more canonical tables missing"
  exit 1
fi
