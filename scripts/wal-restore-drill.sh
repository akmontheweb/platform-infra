#!/usr/bin/env bash
# =============================================================================
# scripts/wal-restore-drill.sh — exercise the WAL/PITR restore path.
#
# What it does:
#   1. Picks a source cluster (platform-postgres or platform-keycloak-postgres).
#   2. Spins up a scratch platform-postgres image with an EMPTY data dir,
#      configured as a recovery replica pointing at the same MinIO bucket.
#   3. wal-g backup-fetch LATEST → fills the scratch PGDATA from the most
#      recent base backup.
#   4. Writes recovery.signal + restore_command, starts postgres in recovery
#      mode. postgres replays WAL segments from MinIO up to PITR target
#      (default: most recent).
#   5. Waits for recovery to finish, runs row-count probes on canonical
#      tables for the chosen DB, tears the scratch container down.
#
# Usage:
#   bash scripts/wal-restore-drill.sh                    # default: platform-postgres + cue DB probes
#   bash scripts/wal-restore-drill.sh keycloak-postgres  # restore keycloak cluster
#   bash scripts/wal-restore-drill.sh postgres '2026-06-09 12:00:00 UTC'  # PITR to a target time
#
# Exit 0 = recovery completed and probes returned counts.
# Exit non-zero = backup-fetch failed, recovery hung, or probe missing.
# =============================================================================
set -euo pipefail

cluster="${1:-postgres}"
pitr_target="${2:-}"

case "${cluster}" in
  postgres)
    source_container="platform-postgres"
    walg_prefix_suffix="platform-postgres"
    probe_db="cue"
    probes=(users tasks audit_logs error_codes)
    src_user="${PLATFORM_PG_SUPERUSER:-platform}"
    ;;
  keycloak-postgres|keycloak)
    source_container="platform-keycloak-postgres"
    walg_prefix_suffix="platform-keycloak-postgres"
    probe_db="keycloak"
    probes=(realm user_entity client)
    src_user="${PLATFORM_KC_DB_USER:-keycloak}"
    ;;
  *)
    echo "unknown cluster: ${cluster} (expected postgres|keycloak-postgres)" >&2
    exit 2
    ;;
esac

bucket="${BACKUP_BUCKET:-platform-backups}"
scratch="wal-drill-${cluster}-$$"
network="platform-infra_default"

log() { printf '[wal-drill %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
cleanup() {
  log "cleanup: docker rm -f ${scratch}"
  docker rm -f "${scratch}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Inherit the wal-g env from the live source container so we read from the
# same MinIO bucket with the same creds. Saves the operator from having to
# pass them as flags.
log "snapshotting wal-g env from ${source_container}"
walg_env="$(docker inspect "${source_container}" 2>/dev/null \
            | grep -oE '"(AWS_[A-Z_]+|WALG_[A-Z_]+)=[^"]*"' \
            | sed 's/^"//; s/"$//')"
if [[ -z "${walg_env}" ]]; then
  log "FAIL: could not read wal-g env from ${source_container} — is it running?"
  exit 1
fi

env_flags=()
while IFS= read -r kv; do
  [[ -n "${kv}" ]] && env_flags+=("-e" "${kv}")
done <<<"${walg_env}"

# Always start the scratch container without any inherited POSTGRES_* vars —
# we want PGDATA EMPTY so wal-g backup-fetch can fill it. Override prefix
# defensively in case the source had a stale value.
env_flags+=("-e" "WALG_S3_PREFIX=s3://${bucket}/wal-g/${walg_prefix_suffix}")
env_flags+=("-e" "PGDATA=/var/lib/postgresql/data")

log "starting scratch container ${scratch} (no postgres yet — recovery setup first)"
docker run -d --rm \
  --name "${scratch}" \
  --network "${network}" \
  --entrypoint sleep \
  "${env_flags[@]}" \
  platform-postgres:latest \
  3600 >/dev/null

# Pull the latest base backup into the scratch PGDATA.
log "wal-g backup-fetch LATEST → /var/lib/postgresql/data"
if ! docker exec "${scratch}" bash -c '
  mkdir -p "${PGDATA}" && chown -R postgres:postgres "${PGDATA}"
  cd /tmp && su postgres -c "wal-g backup-fetch \"${PGDATA}\" LATEST"
'; then
  log "FAIL: wal-g backup-fetch failed — see scratch container logs"
  docker logs "${scratch}" 2>&1 | tail -30
  exit 1
fi

# Write recovery.signal + restore_command so postgres replays WAL from MinIO.
log "writing recovery.signal + restore_command into PGDATA"
recovery_target_clause=""
if [[ -n "${pitr_target}" ]]; then
  recovery_target_clause="recovery_target_time = '${pitr_target}'
recovery_target_action = 'promote'"
  log "PITR target: ${pitr_target}"
else
  log "no PITR target — recovering to end of available WAL"
fi

docker exec "${scratch}" bash -c "
  touch \"\${PGDATA}/recovery.signal\"
  cat >> \"\${PGDATA}/postgresql.auto.conf\" <<EOF
restore_command = 'wal-g wal-fetch %f %p'
${recovery_target_clause}
EOF
  chown postgres:postgres \"\${PGDATA}/recovery.signal\" \"\${PGDATA}/postgresql.auto.conf\"
"

# Boot postgres in recovery mode. We can't reuse the platform-postgres
# entrypoint because it would run with archive_mode=on against the same
# bucket — bad. Run postgres directly with archive_mode=off.
log "starting postgres in recovery mode (archive_mode=off)"
docker exec -d "${scratch}" bash -c '
  su postgres -c "postgres -D ${PGDATA} -c archive_mode=off -c restore_command=\"wal-g wal-fetch %f %p\" 2>&1 | tee /tmp/recovery.log"
'

# Wait for recovery to converge: poll pg_is_in_recovery() until it returns f
# (promoted) or we hit the timeout. With a PITR target + promote action,
# postgres will exit recovery automatically once it reaches the target.
log "waiting up to 120s for recovery to converge"
for i in $(seq 1 60); do
  sleep 2
  if docker exec "${scratch}" pg_isready -U "${src_user}" >/dev/null 2>&1; then
    in_rec=$(docker exec "${scratch}" psql -U "${src_user}" -d postgres -tAc 'SELECT pg_is_in_recovery();' 2>/dev/null || echo "t")
    if [[ "${in_rec}" == "f" ]]; then
      log "recovery converged at iteration ${i} (~$((i*2))s)"
      break
    fi
  fi
  if [[ ${i} -eq 60 ]]; then
    log "FAIL: recovery did not converge in 120s — last 30 lines of recovery log:"
    docker exec "${scratch}" tail -30 /tmp/recovery.log || true
    exit 1
  fi
done

log "probing row counts in restored ${probe_db}:"
all_ok=1
for tbl in "${probes[@]}"; do
  if cnt=$(docker exec "${scratch}" psql -U "${src_user}" -d "${probe_db}" \
              -tAc "SELECT count(*) FROM \"${tbl}\";" 2>/dev/null); then
    printf '  %-32s %s rows\n' "${tbl}" "${cnt}"
  else
    printf '  %-32s MISSING\n' "${tbl}"
    all_ok=0
  fi
done

if (( all_ok == 1 )); then
  log "OK — WAL/PITR drill for ${cluster} passed"
  exit 0
else
  log "FAIL — one or more canonical tables missing"
  exit 1
fi
