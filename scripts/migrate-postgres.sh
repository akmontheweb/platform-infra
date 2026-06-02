#!/usr/bin/env bash
# =============================================================================
# migrate-postgres.sh — Safe Postgres migration: Cue private → platform-infra
#
# WHAT IT DOES:
#   1. Pre-flight checks (source alive, target alive, target DB exists + empty)
#   2. Dumps source DB to a timestamped file in backups/
#   3. Restores into platform-postgres
#   4. Verifies row counts match on key tables
#   5. Prints exact .env lines to update — does NOT edit files automatically
#
# DOES NOT:
#   - Stop any containers (you stop them before running this)
#   - Modify any .env file
#   - Delete source data
#
# USAGE:
#   cd /home/akhila/mywork/projects/platform-infra
#   # 1. Stop Cue write services first:
#   #    docker compose -f ../Cue/docker-compose.yml stop api ai-orchestrator migrate
#   # 2. Run this script:
#   bash scripts/migrate-postgres.sh
#
# ENV VARS (all have defaults matching .env.example):
#   SRC_PG_HOST       default: localhost
#   SRC_PG_PORT       default: 5432
#   SRC_PG_USER       default: cue
#   SRC_PG_PASSWORD   default: (read from SRC_PG_PASSWORD env)
#   SRC_PG_DB         default: cue
#   DST_PG_HOST       default: localhost
#   DST_PG_PORT       default: 5433
#   DST_PG_SUPERUSER  default: platform
#   DST_PG_SUPERPASS  default: (read from DST_PG_SUPERPASS env)
#   DST_PG_USER       default: cue     (project role created by Terraform)
#   DST_PG_PASSWORD   default: (read from DST_PG_PASSWORD env — from Terraform output)
#   DST_PG_DB         default: cue
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/../backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DUMP_FILE="${BACKUP_DIR}/cue_postgres_${TIMESTAMP}.dump"

# --- Source (current Cue private postgres) ----------------------------------
SRC_PG_HOST="${SRC_PG_HOST:-localhost}"
SRC_PG_PORT="${SRC_PG_PORT:-5432}"
SRC_PG_USER="${SRC_PG_USER:-cue}"
SRC_PG_DB="${SRC_PG_DB:-cue}"

# --- Destination (platform-postgres) ----------------------------------------
DST_PG_HOST="${DST_PG_HOST:-localhost}"
DST_PG_PORT="${DST_PG_PORT:-5433}"
DST_PG_SUPERUSER="${DST_PG_SUPERUSER:-platform}"
DST_PG_USER="${DST_PG_USER:-cue}"
DST_PG_DB="${DST_PG_DB:-cue}"

# --- Validation -------------------------------------------------------------
if [[ -z "${SRC_PG_PASSWORD:-}" ]]; then
  echo "ERROR: SRC_PG_PASSWORD is not set. Export it before running this script."
  echo "  export SRC_PG_PASSWORD=<your_cue_postgres_password>"
  exit 1
fi
if [[ -z "${DST_PG_SUPERPASS:-}" ]]; then
  echo "ERROR: DST_PG_SUPERPASS is not set. Export it before running this script."
  echo "  export DST_PG_SUPERPASS=<platform_superuser_password>"
  exit 1
fi
if [[ -z "${DST_PG_PASSWORD:-}" ]]; then
  echo "ERROR: DST_PG_PASSWORD is not set."
  echo "  Get it from: cd terraform && terraform output -raw cue_database_url | sed 's/.*:\(.*\)@.*/\1/'"
  exit 1
fi

mkdir -p "${BACKUP_DIR}"

echo ""
echo "============================================================"
echo "  Postgres Migration: Cue private → platform-infra"
echo "  Source: ${SRC_PG_HOST}:${SRC_PG_PORT}/${SRC_PG_DB}"
echo "  Target: ${DST_PG_HOST}:${DST_PG_PORT}/${DST_PG_DB}"
echo "  Dump:   ${DUMP_FILE}"
echo "============================================================"
echo ""

# --- Pre-flight: source reachable -------------------------------------------
echo "[1/6] Checking source database..."
PGPASSWORD="${SRC_PG_PASSWORD}" psql \
  -h "${SRC_PG_HOST}" -p "${SRC_PG_PORT}" \
  -U "${SRC_PG_USER}" -d "${SRC_PG_DB}" \
  -c "SELECT version();" -t -q > /dev/null \
  || { echo "ERROR: Cannot connect to source database. Is postgres running?"; exit 1; }
echo "      ✓ Source reachable"

# --- Pre-flight: destination reachable + DB exists --------------------------
echo "[2/6] Checking destination database..."
PGPASSWORD="${DST_PG_SUPERPASS}" psql \
  -h "${DST_PG_HOST}" -p "${DST_PG_PORT}" \
  -U "${DST_PG_SUPERUSER}" -d "postgres" \
  -c "SELECT 1 FROM pg_database WHERE datname='${DST_PG_DB}';" -t -q | grep -q 1 \
  || { echo "ERROR: Database '${DST_PG_DB}' does not exist on platform-postgres."; \
       echo "       Run: cd terraform && terraform apply -target=module.cue"; exit 1; }

# Verify target DB is empty (safety check — refuse to overwrite existing data)
TABLE_COUNT=$(PGPASSWORD="${DST_PG_SUPERPASS}" psql \
  -h "${DST_PG_HOST}" -p "${DST_PG_PORT}" \
  -U "${DST_PG_SUPERUSER}" -d "${DST_PG_DB}" \
  -c "SELECT count(*) FROM pg_tables WHERE schemaname='public';" -t -q | tr -d ' ')

if [[ "${TABLE_COUNT}" -gt 0 ]]; then
  echo ""
  echo "WARNING: Target database '${DST_PG_DB}' already has ${TABLE_COUNT} tables."
  echo "         This indicates it was already migrated or has data."
  read -r -p "         Continue and OVERWRITE? (type 'yes' to confirm): " confirm
  if [[ "${confirm}" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
  # Drop and recreate so pg_restore starts clean
  PGPASSWORD="${DST_PG_SUPERPASS}" psql \
    -h "${DST_PG_HOST}" -p "${DST_PG_PORT}" \
    -U "${DST_PG_SUPERUSER}" -d "postgres" \
    -c "DROP DATABASE ${DST_PG_DB}; CREATE DATABASE ${DST_PG_DB} OWNER ${DST_PG_USER};" -q
fi
echo "      ✓ Target ready"

# --- Source row counts (for post-restore verification) ----------------------
echo "[3/6] Sampling source row counts..."
SRC_USERS=$(PGPASSWORD="${SRC_PG_PASSWORD}" psql \
  -h "${SRC_PG_HOST}" -p "${SRC_PG_PORT}" \
  -U "${SRC_PG_USER}" -d "${SRC_PG_DB}" \
  -c "SELECT count(*) FROM users;" -t -q 2>/dev/null | tr -d ' ' || echo "N/A")
SRC_TASKS=$(PGPASSWORD="${SRC_PG_PASSWORD}" psql \
  -h "${SRC_PG_HOST}" -p "${SRC_PG_PORT}" \
  -U "${SRC_PG_USER}" -d "${SRC_PG_DB}" \
  -c "SELECT count(*) FROM tasks;" -t -q 2>/dev/null | tr -d ' ' || echo "N/A")
echo "      users: ${SRC_USERS}, tasks: ${SRC_TASKS}"

# --- Dump -------------------------------------------------------------------
echo "[4/6] Dumping source database (this may take a while)..."
PGPASSWORD="${SRC_PG_PASSWORD}" pg_dump \
  -h "${SRC_PG_HOST}" -p "${SRC_PG_PORT}" \
  -U "${SRC_PG_USER}" -d "${SRC_PG_DB}" \
  --format=custom \
  --no-owner \
  --no-acl \
  --file="${DUMP_FILE}"
DUMP_SIZE=$(du -sh "${DUMP_FILE}" | cut -f1)
echo "      ✓ Dump complete: ${DUMP_FILE} (${DUMP_SIZE})"

# --- Restore ----------------------------------------------------------------
echo "[5/6] Restoring into platform-postgres..."
PGPASSWORD="${DST_PG_SUPERPASS}" pg_restore \
  -h "${DST_PG_HOST}" -p "${DST_PG_PORT}" \
  -U "${DST_PG_SUPERUSER}" \
  -d "${DST_PG_DB}" \
  --no-owner \
  --no-acl \
  --exit-on-error \
  "${DUMP_FILE}"

# Grant restored tables to project role
PGPASSWORD="${DST_PG_SUPERPASS}" psql \
  -h "${DST_PG_HOST}" -p "${DST_PG_PORT}" \
  -U "${DST_PG_SUPERUSER}" -d "${DST_PG_DB}" \
  -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DST_PG_USER};
      GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DST_PG_USER};
      GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${DST_PG_USER};" -q
echo "      ✓ Restore complete"

# --- Verify row counts match ------------------------------------------------
echo "[6/6] Verifying row counts..."
DST_USERS=$(PGPASSWORD="${DST_PG_PASSWORD}" psql \
  -h "${DST_PG_HOST}" -p "${DST_PG_PORT}" \
  -U "${DST_PG_USER}" -d "${DST_PG_DB}" \
  -c "SELECT count(*) FROM users;" -t -q 2>/dev/null | tr -d ' ' || echo "N/A")
DST_TASKS=$(PGPASSWORD="${DST_PG_PASSWORD}" psql \
  -h "${DST_PG_HOST}" -p "${DST_PG_PORT}" \
  -U "${DST_PG_USER}" -d "${DST_PG_DB}" \
  -c "SELECT count(*) FROM tasks;" -t -q 2>/dev/null | tr -d ' ' || echo "N/A")

echo ""
echo "  Table    | Source | Destination | Match?"
echo "  ---------|--------|-------------|-------"
printf "  %-9s| %-7s| %-12s| %s\n" "users" "${SRC_USERS}" "${DST_USERS}" "$([[ "${SRC_USERS}" == "${DST_USERS}" ]] && echo '✓ YES' || echo '✗ MISMATCH')"
printf "  %-9s| %-7s| %-12s| %s\n" "tasks" "${SRC_TASKS}" "${DST_TASKS}" "$([[ "${SRC_TASKS}" == "${DST_TASKS}" ]] && echo '✓ YES' || echo '✗ MISMATCH')"

if [[ "${SRC_USERS}" != "${DST_USERS}" ]] || [[ "${SRC_TASKS}" != "${DST_TASKS}" ]]; then
  echo ""
  echo "ERROR: Row count mismatch detected. DO NOT update .env yet."
  echo "       Dump is preserved at: ${DUMP_FILE}"
  echo "       Investigate and re-run or restore from dump manually."
  exit 1
fi

echo ""
echo "============================================================"
echo "  ✓ MIGRATION SUCCESSFUL"
echo "============================================================"
echo ""
echo "NEXT STEPS:"
echo "  1. Update Cue/.env with these values:"
echo "     DATABASE_URL=postgresql+asyncpg://${DST_PG_USER}:<password>@platform-postgres:5432/${DST_PG_DB}"
echo "     BROADCASTER_URL=postgresql://${DST_PG_USER}:<password>@platform-postgres:5432/${DST_PG_DB}"
echo "     (Get exact values from: cd terraform && terraform output cue_database_url)"
echo ""
echo "  2. Add Cue project to platform network in Cue/docker-compose.yml"
echo ""
echo "  3. Restart Cue services:"
echo "     docker compose -f ../Cue/docker-compose.yml up -d api ai-orchestrator"
echo ""
echo "  4. Test: curl http://localhost:8000/health"
echo ""
echo "  5. After 24h soak with no errors, remove postgres service from Cue/docker-compose.yml"
echo ""
echo "  Source dump preserved at: ${DUMP_FILE}"
echo "  Keep this file for at least 7 days before deleting."
