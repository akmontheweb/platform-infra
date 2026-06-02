#!/usr/bin/env bash
# =============================================================================
# cutover-cue.sh — Final cutover: update Cue docker-compose.yml to use platform-infra
#
# WHEN TO RUN:
#   ONLY after ALL three migrations have been completed and verified:
#     ✓ make migrate-postgres  (row counts match)
#     ✓ make migrate-keycloak  (user counts match, login tested)
#     ✓ make migrate-minio     (object counts match, upload tested)
#   AND after Cue/.env has been updated with platform .env.platform values.
#
# WHAT IT DOES:
#   1. Backs up current Cue-Core/docker-compose.yml
#   2. Removes private infra services: postgres, keycloak-postgres, keycloak,
#      redis, minio, litellm-proxy, and the observability profile stack
#   3. Adds platform-infra_default as external network
#   4. Updates depends_on in api and ai-orchestrator
#   5. Runs `docker compose up -d` to apply changes
#   6. Does NOT delete any Docker volumes (those persist for rollback)
#
# ROLLBACK:
#   bash scripts/cutover-cue.sh --rollback
#   (restores the backed-up docker-compose.yml and restarts)
#
# USAGE:
#   CUE_COMPOSE_DIR=/home/akhila/mywork/projects/Cue/Cue-Core \
#   bash scripts/cutover-cue.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/../backups"
CUE_COMPOSE_DIR="${CUE_COMPOSE_DIR:-/home/akhila/mywork/projects/Cue/Cue-Core}"
COMPOSE_FILE="${CUE_COMPOSE_DIR}/docker-compose.yml"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/cue_docker-compose_${TIMESTAMP}.yml"

mkdir -p "${BACKUP_DIR}"

# ── Rollback mode ────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--rollback" ]]; then
  LATEST_BACKUP=$(ls -t "${BACKUP_DIR}"/cue_docker-compose_*.yml 2>/dev/null | head -1)
  if [[ -z "${LATEST_BACKUP}" ]]; then
    echo "ERROR: No docker-compose backup found in ${BACKUP_DIR}"
    exit 1
  fi
  echo "Rolling back to: ${LATEST_BACKUP}"
  cp "${LATEST_BACKUP}" "${COMPOSE_FILE}"
  echo "✓ Restored. Restart Cue:"
  echo "  cd ${CUE_COMPOSE_DIR} && docker compose up -d"
  exit 0
fi

# ── Pre-flight ────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Cue Cutover: Remove private infra, join platform-infra"
echo "  Compose file: ${COMPOSE_FILE}"
echo "============================================================"
echo ""

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "ERROR: ${COMPOSE_FILE} not found."
  echo "  Set CUE_COMPOSE_DIR to the directory containing Cue's docker-compose.yml"
  exit 1
fi

# Verify platform-infra is running
if ! docker network inspect platform-infra_default &>/dev/null; then
  echo "ERROR: Docker network 'platform-infra_default' not found."
  echo "  Start platform-infra first: cd platform-infra && make up"
  exit 1
fi
echo "  ✓ platform-infra_default network is available"

# Quick sanity check: platform-postgres is reachable
if ! docker exec platform-postgres pg_isready -U platform &>/dev/null; then
  echo "ERROR: platform-postgres is not healthy."
  echo "  Check: make logs-postgres"
  exit 1
fi
echo "  ✓ platform-postgres is healthy"

echo ""
echo "This will:"
echo "  • Remove from docker-compose.yml: postgres, keycloak-postgres, keycloak,"
echo "    redis, minio, litellm-proxy, otel-collector, jaeger, prometheus, grafana"
echo "  • Add external network: platform-infra_default"
echo "  • Update api/ai-orchestrator/voice-processor depends_on"
echo "  • Restart Cue services"
echo ""
echo "Rollback: bash scripts/cutover-cue.sh --rollback"
echo ""
read -r -p "Type 'cutover' to proceed: " confirm
[[ "${confirm}" == "cutover" ]] || { echo "Aborted."; exit 0; }

# ── Backup ────────────────────────────────────────────────────────────────────
cp "${COMPOSE_FILE}" "${BACKUP_FILE}"
echo ""
echo "  ✓ Backup saved: ${BACKUP_FILE}"

# ── Write new docker-compose.yml ─────────────────────────────────────────────
cat > "${COMPOSE_FILE}" << 'COMPOSE_EOF'
# ─────────────────────────────────────────────────────────────
# Cue-Core – Application services only (post platform-infra migration)
#
# Infra services (postgres, keycloak, redis, minio, litellm) are now
# provided by platform-infra. This file only runs Cue application services.
#
# Requires:
#   - platform-infra running: cd platform-infra && make up
#   - .env updated with values from terraform/projects/cue/.env.platform
#
# Usage: docker compose up --build -d
# ─────────────────────────────────────────────────────────────

x-otel-env: &otel-env
  OTEL_TRACES_SAMPLER: ${OTEL_TRACES_SAMPLER:-parentbased_traceidratio}
  OTEL_TRACES_SAMPLER_ARG: ${OTEL_TRACES_SAMPLER_ARG:-1.0}
  OTEL_RESOURCE_ATTRIBUTES: ${OTEL_RESOURCE_ATTRIBUTES:-service.namespace=cue,deployment.environment=production}
  OTEL_EXPORTER_OTLP_ENDPOINT: ${OTEL_EXPORTER_OTLP_ENDPOINT:-http://platform-otel-collector:4317}
  OTEL_EXPORTER_OTLP_INSECURE: ${OTEL_EXPORTER_OTLP_INSECURE:-true}

x-python-service: &python-service
  restart: unless-stopped
  networks:
    - Cue
    - platform

services:
  # ── FastAPI Main Backend ───────────────────────────────────────
  api:
    build:
      context: ./services/api
      dockerfile: Dockerfile
      target: production
    image: cue-core-api:latest
    <<: *python-service
    environment:
      <<: *otel-env
      DATABASE_URL: ${DATABASE_URL:?DATABASE_URL required}
      BROADCASTER_URL: ${BROADCASTER_URL:?BROADCASTER_URL required}
      REDIS_URL: ${REDIS_URL:?REDIS_URL required}
      KEYCLOAK_URL: ${KEYCLOAK_URL:?KEYCLOAK_URL required}
      KEYCLOAK_PUBLIC_URL: ${KEYCLOAK_PUBLIC_URL:-}
      KEYCLOAK_REALM: ${KEYCLOAK_REALM:-Cue-app}
      KEYCLOAK_CLIENT_SECRET: ${KC_BACKEND_SERVICE_SECRET:?KC_BACKEND_SERVICE_SECRET required}
      OTEL_SERVICE_NAME: Cue-api
      ENABLE_OBSERVABILITY_STACK: ${ENABLE_OBSERVABILITY_STACK:-true}
      FERNET_KEY: ${FERNET_KEY:?FERNET_KEY required}
      TWILIO_ACCOUNT_SID: ${TWILIO_ACCOUNT_SID:-}
      TWILIO_AUTH_TOKEN: ${TWILIO_AUTH_TOKEN:-}
      TWILIO_PHONE_NUMBER: ${TWILIO_PHONE_NUMBER:-}
      TWILIO_SUPPORT_PHONE_NUMBER: ${TWILIO_SUPPORT_PHONE_NUMBER:-}
      GEO_REMINDER_ENABLED: ${GEO_REMINDER_ENABLED:-false}
      IMAGE_CAPTURE_ENABLED: ${IMAGE_CAPTURE_ENABLED:-true}
      VOICE_PROCESSOR_URL: ${VOICE_PROCESSOR_URL:?VOICE_PROCESSOR_URL required}
      INTERNAL_TRANSCRIBE_TOKEN: ${INTERNAL_TRANSCRIBE_TOKEN:?INTERNAL_TRANSCRIBE_TOKEN required}
      CORS_ORIGINS: ${CORS_ORIGINS:?CORS_ORIGINS required}
      WEBAUTHN_RP_ID: ${WEBAUTHN_RP_ID:-localhost}
      WEBAUTHN_RP_NAME: ${WEBAUTHN_RP_NAME:-Cue}
      WEBAUTHN_ORIGIN: ${WEBAUTHN_ORIGIN:-http://localhost:8888}
      SMTP_HOST: ${SMTP_HOST:-}
      SMTP_PORT: ${SMTP_PORT:-465}
      SMTP_USER: ${SMTP_USER:-resend}
      SMTP_PASSWORD: ${SMTP_PASSWORD:-}
      SMTP_FROM: ${SMTP_FROM:-onboarding@resend.dev}
      MINIO_ENDPOINT: ${MINIO_ENDPOINT:-platform-minio:9000}
      MINIO_ACCESS_KEY: ${MINIO_ACCESS_KEY:?MINIO_ACCESS_KEY required}
      MINIO_SECRET_KEY: ${MINIO_SECRET_KEY:?MINIO_SECRET_KEY required}
      MINIO_BUCKET_IMAGES: ${MINIO_BUCKET_IMAGES:-cue-images}
      MINIO_SECURE: ${MINIO_SECURE:-false}
    ports:
      - "${API_PORT}:8000"
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8000/health"]
      interval: 15s
      timeout: 5s
      retries: 5

  # ── LangGraph AI Orchestrator ─────────────────────────────────
  ai-orchestrator:
    build:
      context: ./services/ai-orchestrator
      dockerfile: Dockerfile
      target: production
    image: cue-core-ai-orchestrator:latest
    <<: *python-service
    environment:
      <<: *otel-env
      DATABASE_URL: ${DATABASE_URL:?DATABASE_URL required}
      REDIS_URL: ${REDIS_URL:?REDIS_URL required}
      LITELLM_PROXY_URL: ${LITELLM_PROXY_URL:?LITELLM_PROXY_URL required}
      LITELLM_API_KEY: ${LITELLM_API_KEY:-}
      OTEL_SERVICE_NAME: Cue-ai-orchestrator
      ENABLE_OBSERVABILITY_STACK: ${ENABLE_OBSERVABILITY_STACK:-true}
      TAVILY_API_KEY: ${TAVILY_API_KEY:-}
      OPENAI_API_KEY: ${OPENAI_API_KEY:-}
      VOICE_PROCESSOR_URL: ${VOICE_PROCESSOR_URL:?VOICE_PROCESSOR_URL required}
      GEO_REMINDER_ENABLED: ${GEO_REMINDER_ENABLED:-false}
      IMAGE_CAPTURE_ENABLED: ${IMAGE_CAPTURE_ENABLED:-true}
      TWILIO_ACCOUNT_SID: ${TWILIO_ACCOUNT_SID:-}
      TWILIO_AUTH_TOKEN: ${TWILIO_AUTH_TOKEN:-}
      TWILIO_PHONE_NUMBER: ${TWILIO_PHONE_NUMBER:-}
      MINIO_ENDPOINT: ${MINIO_ENDPOINT:-platform-minio:9000}
      MINIO_ACCESS_KEY: ${MINIO_ACCESS_KEY:?MINIO_ACCESS_KEY required}
      MINIO_SECRET_KEY: ${MINIO_SECRET_KEY:?MINIO_SECRET_KEY required}
      MINIO_BUCKET_IMAGES: ${MINIO_BUCKET_IMAGES:-cue-images}
      MINIO_SECURE: ${MINIO_SECURE:-false}

  # ── Whisper Voice Processor ───────────────────────────────────
  voice-processor:
    build:
      context: ./services/voice-processor
      dockerfile: Dockerfile
      target: production
    image: cue-core-voice-processor:latest
    <<: *python-service
    environment:
      <<: *otel-env
      LITELLM_PROXY_URL: ${LITELLM_PROXY_URL:?LITELLM_PROXY_URL required}
      INTERNAL_TRANSCRIBE_TOKEN: ${INTERNAL_TRANSCRIBE_TOKEN:?INTERNAL_TRANSCRIBE_TOKEN required}
      OTEL_SERVICE_NAME: Cue-voice-processor
      ENABLE_OBSERVABILITY_STACK: ${ENABLE_OBSERVABILITY_STACK:-true}

  # ── Caddy (TLS termination + reverse proxy) ───────────────────
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    networks:
      - Cue
      - Cue-Web
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./infra/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - api
    environment:
      DOMAIN: ${DOMAIN:?DOMAIN required}
      CADDY_OBS_USER: ${CADDY_OBS_USER:-admin}
      CADDY_OBS_PASSWORD_HASH: ${CADDY_OBS_PASSWORD_HASH:?CADDY_OBS_PASSWORD_HASH required}

volumes:
  caddy_data:
  caddy_config:

networks:
  Cue:
    name: Cue-network
    driver: bridge
  Cue-Web:
    name: Cue-Web-network
    external: true
  platform:
    name: platform-infra_default
    external: true
COMPOSE_EOF

echo "  ✓ New docker-compose.yml written"

# ── Restart Cue services ──────────────────────────────────────────────────────
echo ""
echo "Restarting Cue services..."
cd "${CUE_COMPOSE_DIR}"
docker compose up -d --remove-orphans

echo ""
echo "============================================================"
echo "  ✓ CUTOVER COMPLETE"
echo "============================================================"
echo ""
echo "Cue services are now running against platform-infra."
echo ""
echo "VERIFY:"
echo "  curl http://localhost:${API_PORT:-8000}/health"
echo "  # Test login, task creation, image upload"
echo ""
echo "MONITOR for 24h:"
echo "  docker compose logs -f api ai-orchestrator"
echo ""
echo "AFTER 24h SOAK with no errors:"
echo "  # Remove old private volumes (ONLY after confirming platform data is correct):"
echo "  docker volume rm cue-core_postgres_data cue-core_keycloak_postgres_data"
echo "  docker volume rm cue-core_redis_data cue-core_minio_data"
echo ""
echo "ROLLBACK (if needed):"
echo "  bash $(realpath ${SCRIPT_DIR})/cutover-cue.sh --rollback"
