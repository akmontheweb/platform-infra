#!/usr/bin/env bash
# =============================================================================
# migrate-minio.sh — Zero-downtime MinIO migration: Cue private → platform-infra
#
# WHAT IT DOES:
#   1. Pre-flight checks (both MinIO instances reachable, mc available)
#   2. Creates mc aliases for source and destination
#   3. Mirrors all source buckets to destination (live copy)
#   4. Reports object counts before and after
#   5. Prints exact .env lines to update — does NOT edit files automatically
#
# ZERO DOWNTIME STRATEGY:
#   - mc mirror runs a full copy; re-run at any time without risk
#   - During cutover: run once more to catch any new objects uploaded during migration
#   - No source data is deleted at any point
#
# USAGE:
#   cd /home/akhila/mywork/projects/platform-infra
#   bash scripts/migrate-minio.sh
#
# ENV VARS:
#   SRC_MINIO_URL     default: http://localhost:9000
#   SRC_ACCESS_KEY    default: CueDev001
#   SRC_SECRET_KEY    (required)
#   DST_MINIO_URL     default: http://localhost:9002
#   DST_ACCESS_KEY    default: platform
#   DST_SECRET_KEY    (required)
#   BUCKETS           space-separated list; default: cue-images cue-docs
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRC_MINIO_URL="${SRC_MINIO_URL:-http://localhost:9000}"
SRC_ACCESS_KEY="${SRC_ACCESS_KEY:-CueDev001}"

DST_MINIO_URL="${DST_MINIO_URL:-http://localhost:9002}"
DST_ACCESS_KEY="${DST_ACCESS_KEY:-platform}"

BUCKETS="${BUCKETS:-cue-images cue-docs}"

# --- Validation ------------------------------------------------------------
if [[ -z "${SRC_SECRET_KEY:-}" ]]; then
  echo "ERROR: SRC_SECRET_KEY is not set."
  echo "  export SRC_SECRET_KEY=<cue_minio_secret>"
  exit 1
fi
if [[ -z "${DST_SECRET_KEY:-}" ]]; then
  echo "ERROR: DST_SECRET_KEY is not set."
  echo "  export DST_SECRET_KEY=<platform_minio_root_password>"
  exit 1
fi

# --- Ensure mc is available ------------------------------------------------
if ! command -v mc &>/dev/null; then
  echo "mc (MinIO Client) is not installed. Installing..."
  # Try snap first (Linux), then direct download
  if command -v snap &>/dev/null; then
    sudo snap install minio-client
  else
    curl -sSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /tmp/mc
    chmod +x /tmp/mc
    sudo mv /tmp/mc /usr/local/bin/mc
  fi
  echo "mc installed."
fi

echo ""
echo "============================================================"
echo "  MinIO Migration: Cue private → platform-infra"
echo "  Source: ${SRC_MINIO_URL}"
echo "  Target: ${DST_MINIO_URL}"
echo "  Buckets: ${BUCKETS}"
echo "============================================================"
echo ""

# --- Configure mc aliases --------------------------------------------------
echo "[1/4] Configuring mc aliases..."
mc alias set cue-src "${SRC_MINIO_URL}" "${SRC_ACCESS_KEY}" "${SRC_SECRET_KEY}" --api S3v4 -q
mc alias set cue-dst "${DST_MINIO_URL}" "${DST_ACCESS_KEY}" "${DST_SECRET_KEY}" --api S3v4 -q
echo "      ✓ Aliases configured"

# --- Count source objects --------------------------------------------------
echo "[2/4] Counting source objects..."
declare -A SRC_COUNTS
for bucket in ${BUCKETS}; do
  count=$(mc ls --recursive "cue-src/${bucket}" 2>/dev/null | wc -l || echo "0")
  SRC_COUNTS["${bucket}"]="${count}"
  echo "      ${bucket}: ${count} objects"
done

# --- Ensure destination buckets exist --------------------------------------
echo "[3/4] Ensuring destination buckets exist..."
for bucket in ${BUCKETS}; do
  if ! mc ls "cue-dst/${bucket}" &>/dev/null; then
    mc mb "cue-dst/${bucket}" -q
    echo "      Created bucket: ${bucket}"
  else
    echo "      Bucket exists: ${bucket}"
  fi
done

# --- Mirror all buckets ----------------------------------------------------
echo "[4/4] Mirroring buckets..."
FAILED_BUCKETS=()
for bucket in ${BUCKETS}; do
  echo ""
  echo "  Mirroring: ${bucket} ..."
  if mc mirror --overwrite "cue-src/${bucket}" "cue-dst/${bucket}"; then
    DST_COUNT=$(mc ls --recursive "cue-dst/${bucket}" 2>/dev/null | wc -l || echo "0")
    SRC_COUNT="${SRC_COUNTS[$bucket]:-0}"
    echo "  Source: ${SRC_COUNT} objects  →  Destination: ${DST_COUNT} objects"
    if [[ "${SRC_COUNT}" != "${DST_COUNT}" ]]; then
      echo "  WARNING: Count mismatch for ${bucket}"
      FAILED_BUCKETS+=("${bucket}")
    else
      echo "  ✓ ${bucket} verified"
    fi
  else
    echo "  ERROR: Mirror failed for ${bucket}"
    FAILED_BUCKETS+=("${bucket}")
  fi
done

echo ""
if [[ ${#FAILED_BUCKETS[@]} -gt 0 ]]; then
  echo "============================================================"
  echo "  WARNING: Some buckets may have issues: ${FAILED_BUCKETS[*]}"
  echo "  Re-run this script to retry before cutting over."
  echo "============================================================"
else
  echo "============================================================"
  echo "  ✓ MIGRATION SUCCESSFUL — all objects mirrored"
  echo "============================================================"
fi

echo ""
echo "NEXT STEPS:"
echo "  1. At cutover time, run this script once more to catch any new uploads:"
echo "     bash scripts/migrate-minio.sh"
echo ""
echo "  2. Update Cue/.env:"
echo "     MINIO_ENDPOINT=platform-minio:9000"
echo "     MINIO_ACCESS_KEY=<from terraform output: cue_minio_access_key>"
echo "     MINIO_SECRET_KEY=<from terraform output: cue_minio_secret_key>"
echo "     MINIO_BUCKET=cue-images"
echo "     MINIO_SECURE=false"
echo ""
echo "  3. Restart Cue api"
echo ""
echo "  4. Test an image upload in the app"
echo ""
echo "  5. After 24h soak, remove MinIO from Cue/docker-compose.yml"
echo ""
echo "  Source MinIO data is preserved — nothing was deleted."
