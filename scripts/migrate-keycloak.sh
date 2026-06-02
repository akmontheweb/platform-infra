#!/usr/bin/env bash
# =============================================================================
# migrate-keycloak.sh — Safe Keycloak migration: Cue private → platform-infra
#
# WHAT IT DOES:
#   1. Pre-flight checks (source and target Keycloak alive, admin tokens work)
#   2. Exports Cue-app realm WITH users from the running Cue Keycloak container
#   3. Verifies export file is valid JSON and contains users
#   4. Imports realm into platform-keycloak via Admin REST API
#   5. Verifies user count matches
#   6. Prints exact .env lines to update — does NOT edit files automatically
#
# IMPORTANT:
#   - Active sessions will be invalidated. Users must log in once after cutover.
#   - Accounts, passwords (hashed), roles, groups: fully preserved.
#   - The export includes hashed credential data (passwords remain valid).
#
# USAGE:
#   cd /home/akhila/mywork/projects/platform-infra
#   bash scripts/migrate-keycloak.sh
#
# ENV VARS:
#   SRC_KC_CONTAINER   default: cue-keycloak-1
#   SRC_KC_URL         default: http://localhost:8080
#   SRC_KC_ADMIN_USER  default: admin
#   SRC_KC_ADMIN_PASS  (required)
#   SRC_KC_REALM       default: Cue-app
#   DST_KC_URL         default: http://localhost:8081
#   DST_KC_ADMIN_USER  default: admin
#   DST_KC_ADMIN_PASS  (required)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/../backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
EXPORT_FILE="${BACKUP_DIR}/cue_keycloak_realm_${TIMESTAMP}.json"

SRC_KC_CONTAINER="${SRC_KC_CONTAINER:-cue-keycloak-1}"
SRC_KC_URL="${SRC_KC_URL:-http://localhost:8080}"
SRC_KC_ADMIN_USER="${SRC_KC_ADMIN_USER:-admin}"
SRC_KC_REALM="${SRC_KC_REALM:-Cue-app}"

DST_KC_URL="${DST_KC_URL:-http://localhost:8081}"
DST_KC_ADMIN_USER="${DST_KC_ADMIN_USER:-admin}"

# --- Validation ------------------------------------------------------------
if [[ -z "${SRC_KC_ADMIN_PASS:-}" ]]; then
  echo "ERROR: SRC_KC_ADMIN_PASS is not set."
  echo "  export SRC_KC_ADMIN_PASS=<cue_keycloak_admin_password>"
  exit 1
fi
if [[ -z "${DST_KC_ADMIN_PASS:-}" ]]; then
  echo "ERROR: DST_KC_ADMIN_PASS is not set."
  echo "  export DST_KC_ADMIN_PASS=<platform_keycloak_admin_password>"
  exit 1
fi

mkdir -p "${BACKUP_DIR}"

echo ""
echo "============================================================"
echo "  Keycloak Migration: Cue private → platform-infra"
echo "  Source: ${SRC_KC_URL} (realm: ${SRC_KC_REALM})"
echo "  Target: ${DST_KC_URL}"
echo "  Export: ${EXPORT_FILE}"
echo "============================================================"
echo ""

# --- Pre-flight: source admin token ----------------------------------------
echo "[1/6] Checking source Keycloak..."
SRC_TOKEN=$(curl -sf -X POST \
  "${SRC_KC_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=admin-cli&username=${SRC_KC_ADMIN_USER}&password=${SRC_KC_ADMIN_PASS}&grant_type=password" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])") \
  || { echo "ERROR: Cannot get admin token from source Keycloak."; exit 1; }
echo "      ✓ Source admin authenticated"

# --- Pre-flight: destination admin token -----------------------------------
echo "[2/6] Checking destination Keycloak..."
DST_TOKEN=$(curl -sf -X POST \
  "${DST_KC_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=admin-cli&username=${DST_KC_ADMIN_USER}&password=${DST_KC_ADMIN_PASS}&grant_type=password" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])") \
  || { echo "ERROR: Cannot get admin token from destination Keycloak."; exit 1; }

# Check if realm already exists in destination
REALM_EXISTS=$(curl -sf -o /dev/null -w "%{http_code}" \
  "${DST_KC_URL}/admin/realms/${SRC_KC_REALM}" \
  -H "Authorization: Bearer ${DST_TOKEN}" || echo "000")

if [[ "${REALM_EXISTS}" == "200" ]]; then
  echo ""
  echo "WARNING: Realm '${SRC_KC_REALM}' already exists in destination Keycloak."
  read -r -p "         Delete and reimport? (type 'yes' to confirm): " confirm
  if [[ "${confirm}" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
  curl -sf -X DELETE \
    "${DST_KC_URL}/admin/realms/${SRC_KC_REALM}" \
    -H "Authorization: Bearer ${DST_TOKEN}"
  echo "      Existing realm deleted."
fi
echo "      ✓ Destination ready"

# --- Export realm WITH users from running container -------------------------
echo "[3/6] Exporting realm with users from source container..."
# kc.sh export is the only reliable way to get hashed passwords
docker exec "${SRC_KC_CONTAINER}" \
  /opt/keycloak/bin/kc.sh export \
  --realm "${SRC_KC_REALM}" \
  --users realm_file \
  --file /tmp/realm_export_migration.json 2>&1 | tail -5

docker cp "${SRC_KC_CONTAINER}:/tmp/realm_export_migration.json" "${EXPORT_FILE}"

# Verify file is valid JSON and has users
USER_COUNT_IN_EXPORT=$(python3 -c "
import json, sys
with open('${EXPORT_FILE}') as f:
    data = json.load(f)
users = [u for u in data.get('users', []) if u.get('username') != 'service-account-backend-service']
print(len(users))
" 2>/dev/null || echo "0")

echo "      ✓ Export complete: ${USER_COUNT_IN_EXPORT} user accounts in export"

if [[ "${USER_COUNT_IN_EXPORT}" -eq 0 ]]; then
  # Check if there are really no users or if export failed
  SRC_USER_COUNT=$(curl -sf \
    "${SRC_KC_URL}/admin/realms/${SRC_KC_REALM}/users?max=1&briefRepresentation=true" \
    -H "Authorization: Bearer ${SRC_TOKEN}" \
    | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")
  echo ""
  echo "INFO: 0 users in export, but source has ~${SRC_USER_COUNT} users."
  echo "      This may be expected for a fresh or test environment."
  read -r -p "      Continue? (type 'yes' to confirm): " confirm
  [[ "${confirm}" == "yes" ]] || exit 0
fi

# --- Get source user count for verification --------------------------------
echo "[4/6] Sampling source user count..."
SRC_USERS=$(curl -sf \
  "${SRC_KC_URL}/admin/realms/${SRC_KC_REALM}/users/count" \
  -H "Authorization: Bearer ${SRC_TOKEN}" \
  2>/dev/null || echo "N/A")
echo "      Source has ${SRC_USERS} total users (including service accounts)"

# --- Import into destination -----------------------------------------------
echo "[5/6] Importing realm into platform-keycloak..."
# Keycloak's POST /admin/realms accepts the full realm representation
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${DST_KC_URL}/admin/realms" \
  -H "Authorization: Bearer ${DST_TOKEN}" \
  -H "Content-Type: application/json" \
  --data-binary "@${EXPORT_FILE}")

if [[ "${HTTP_STATUS}" != "201" ]]; then
  echo "ERROR: Import returned HTTP ${HTTP_STATUS}. Check platform-keycloak logs:"
  echo "  docker logs platform-keycloak --tail 30"
  exit 1
fi
echo "      ✓ Import complete (HTTP 201)"

# --- Verify user count matches ---------------------------------------------
echo "[6/6] Verifying user count..."
# Get a fresh token for destination (old token may have expired)
DST_TOKEN=$(curl -sf -X POST \
  "${DST_KC_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=admin-cli&username=${DST_KC_ADMIN_USER}&password=${DST_KC_ADMIN_PASS}&grant_type=password" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

DST_USERS=$(curl -sf \
  "${DST_KC_URL}/admin/realms/${SRC_KC_REALM}/users/count" \
  -H "Authorization: Bearer ${DST_TOKEN}" \
  2>/dev/null || echo "N/A")

echo ""
echo "  Source users: ${SRC_USERS}"
echo "  Target users: ${DST_USERS}"

if [[ "${SRC_USERS}" != "${DST_USERS}" ]]; then
  echo ""
  echo "WARNING: User count mismatch (${SRC_USERS} vs ${DST_USERS})."
  echo "         This may be expected if service accounts differ."
  echo "         Manually verify a few users can log in before updating .env."
else
  echo "  ✓ User count matches"
fi

echo ""
echo "============================================================"
echo "  ✓ REALM IMPORT SUCCESSFUL"
echo "============================================================"
echo ""
echo "NEXT STEPS:"
echo "  1. Re-run CORS and scopes scripts against platform-keycloak:"
echo "     KC_ADMIN_PASSWORD='${DST_KC_ADMIN_PASS}' \\"
echo "     bash ../Cue/scripts/fix-keycloak-cors.sh http://localhost:8081"
echo "     KC_ADMIN_PASSWORD='${DST_KC_ADMIN_PASS}' \\"
echo "     bash ../Cue/scripts/fix-keycloak-scopes.sh http://localhost:8081"
echo ""
echo "  2. Test login via web app pointing at platform-keycloak:"
echo "     VITE_KEYCLOAK_URL=http://10.0.0.95:8081 (temporarily)"
echo ""
echo "  3. Update Cue/.env:"
echo "     KEYCLOAK_URL=http://platform-keycloak:8080"
echo "     KEYCLOAK_PUBLIC_URL=http://10.0.0.95:8080    ← KC_PORT on platform is 8081 externally"
echo "     KC_BACKEND_SERVICE_SECRET=<from terraform output>"
echo ""
echo "  4. Restart Cue api + ai-orchestrator"
echo ""
echo "  5. After 24h soak, remove keycloak + keycloak-postgres from Cue/docker-compose.yml"
echo ""
echo "  Export preserved at: ${EXPORT_FILE}"
echo "  KEEP THIS FILE — it contains all user credentials (hashed)."
