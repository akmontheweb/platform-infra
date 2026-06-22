.PHONY: up down logs build ps shell-postgres shell-redis provision rollback help \
        secrets-install secrets-keygen secrets-encrypt secrets-decrypt secrets-verify \
        tf-bootstrap tf-init-remote tf-apply-all

COMPOSE = docker compose
TF = cd terraform && terraform

# Default project for `make provision`
PROJECT ?= cue

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ─── Docker ──────────────────────────────────────────────────────────────────

build: ## Build all platform images
	$(COMPOSE) build

up: ## Start all platform services (detached)
	$(COMPOSE) up -d
	@echo ""
	@echo "Platform services starting. Check health with: make ps"
	@echo "Keycloak needs ~60s to become healthy."

down: ## Stop all platform services (preserves volumes)
	$(COMPOSE) down

down-volumes: ## ⚠ Stop and DELETE all platform volumes (DESTRUCTIVE)
	@echo "WARNING: This will delete ALL platform data (postgres, keycloak, redis, minio)."
	@read -p "Type 'yes' to confirm: " c && [ "$$c" = "yes" ]
	$(COMPOSE) down -v

logs: ## Tail all platform logs
	$(COMPOSE) logs -f

logs-%: ## Tail logs for a specific service: make logs-postgres
	$(COMPOSE) logs -f platform-$*

ps: ## Show platform service health status
	$(COMPOSE) ps

restart-%: ## Restart a specific service: make restart-keycloak
	$(COMPOSE) restart platform-$*

# ─── Secrets (SOPS + age) ────────────────────────────────────────────────────

secrets-install: ## Install sops + age binaries into ~/.local/bin
	bash scripts/setup-sops.sh install

secrets-keygen: ## Generate the production age keypair (one-time)
	bash scripts/setup-sops.sh keygen

secrets-encrypt: ## Encrypt .env.production → .env.production.enc
	bash scripts/setup-sops.sh encrypt

secrets-decrypt: ## Decrypt .env.production.enc → .env.production
	bash scripts/setup-sops.sh decrypt

secrets-verify: ## CI gate: fail if any tracked .env* is cleartext
	bash scripts/setup-sops.sh verify

# ─── Terraform ───────────────────────────────────────────────────────────────

tf-bootstrap: ## One-time: create MinIO bucket + service account for TF state
	@set -a && . ./.env && set +a && \
	docker exec -i platform-minio mc alias set local http://localhost:9000 \
	    "$$PLATFORM_MINIO_ROOT_USER" "$$PLATFORM_MINIO_ROOT_PASSWORD" && \
	docker exec -i platform-minio mc mb -p local/platform-tfstate && \
	docker exec -i platform-minio mc version enable local/platform-tfstate && \
	docker exec -i platform-minio mc admin user add local \
	    "$$TF_BACKEND_ACCESS_KEY" "$$TF_BACKEND_SECRET_KEY" && \
	docker exec -i platform-minio mc admin policy attach local readwrite \
	    --user "$$TF_BACKEND_ACCESS_KEY"
	@echo "✓ TF state bucket ready: platform-tfstate"

tf-init: ## Initialize Terraform providers (local backend — legacy)
	$(TF) init

tf-init-remote: ## Initialize Terraform with the MinIO S3 backend
	# Overrides on top of backend.tf:
	#   endpoints.s3 → localhost:<host-port>  (terraform runs on the host,
	#                  not in the docker network; same port on dev + prod)
	#   encrypt      → false (MinIO doesn't have KMS / SSE-S3 configured;
	#                  enable via `mc encrypt set sse-s3 …` and flip back on
	#                  if/when at-rest encryption is required)
	@set -a && . ./.env && set +a && \
	$(TF) init -reconfigure -input=false \
	    -backend-config="access_key=$$TF_BACKEND_ACCESS_KEY" \
	    -backend-config="secret_key=$$TF_BACKEND_SECRET_KEY" \
	    -backend-config="endpoints={s3=\"http://localhost:$${PLATFORM_MINIO_PORT:-9002}\"}" \
	    -backend-config="encrypt=false"

provision: ## Provision a project namespace: make provision PROJECT=cue
	@echo "Provisioning project: $(PROJECT)"
	$(TF) init
	$(TF) apply -target=module.$(PROJECT)
	@echo ""
	@echo "✓ Done. .env.platform file generated at terraform/projects/$(PROJECT)/.env.platform"

deploy-mcp: ## Build, provision LiteLLM key, and deploy platform-mcp via Terraform
	@set -a && . ./.env && set +a && \
	export TF_VAR_pg_superpassword=$$PLATFORM_PG_SUPERPASSWORD && \
	export TF_VAR_kc_admin_password=$$PLATFORM_KC_ADMIN_PASSWORD && \
	export TF_VAR_minio_root_password=$$PLATFORM_MINIO_ROOT_PASSWORD && \
	export TF_VAR_litellm_master_key=$$LITELLM_MASTER_KEY && \
	export TF_VAR_redis_password=$$PLATFORM_REDIS_PASSWORD && \
	export TF_VAR_mcp_api_key=$$MCP_API_KEY && \
	export TF_VAR_mcp_smtp_host=$$SMTP_HOST && \
	export TF_VAR_mcp_smtp_port=$$SMTP_PORT && \
	export TF_VAR_mcp_smtp_user=$$SMTP_USER && \
	export TF_VAR_mcp_smtp_password=$$SMTP_PASSWORD && \
	export TF_VAR_mcp_smtp_from=$$SMTP_FROM && \
	export TF_VAR_mcp_twilio_account_sid=$$TWILIO_ACCOUNT_SID && \
	export TF_VAR_mcp_twilio_auth_token=$$TWILIO_AUTH_TOKEN && \
	export TF_VAR_mcp_twilio_phone_number=$$TWILIO_PHONE_NUMBER && \
	export TF_VAR_mcp_tavily_api_key=$$TAVILY_API_KEY && \
	cd terraform && terraform apply -target=null_resource.mcp_deploy -auto-approve
	@echo ""
	@echo "✓ platform-mcp deployed. services/mcp/.env written with LiteLLM key."

provision-plan: ## Dry-run for provisioning: make provision-plan PROJECT=cue
	$(TF) init
	$(TF) plan -target=module.$(PROJECT)

tf-apply-all: ## Apply ALL Terraform modules (used by CompleteRefresh)
	@set -a && . ./.env && set +a && \
	export TF_VAR_pg_superpassword=$$PLATFORM_PG_SUPERPASSWORD && \
	export TF_VAR_kc_admin_password=$$PLATFORM_KC_ADMIN_PASSWORD && \
	export TF_VAR_minio_root_password=$$PLATFORM_MINIO_ROOT_PASSWORD && \
	export TF_VAR_litellm_master_key=$$LITELLM_MASTER_KEY && \
	export TF_VAR_redis_password=$$PLATFORM_REDIS_PASSWORD && \
	export TF_VAR_mcp_api_key=$$MCP_API_KEY && \
	export TF_VAR_mcp_smtp_host=$$SMTP_HOST && \
	export TF_VAR_mcp_smtp_port=$$SMTP_PORT && \
	export TF_VAR_mcp_smtp_user=$$SMTP_USER && \
	export TF_VAR_mcp_smtp_password=$$SMTP_PASSWORD && \
	export TF_VAR_mcp_smtp_from=$$SMTP_FROM && \
	export TF_VAR_mcp_twilio_account_sid=$$TWILIO_ACCOUNT_SID && \
	export TF_VAR_mcp_twilio_auth_token=$$TWILIO_AUTH_TOKEN && \
	export TF_VAR_mcp_twilio_phone_number=$$TWILIO_PHONE_NUMBER && \
	export TF_VAR_mcp_tavily_api_key=$$TAVILY_API_KEY && \
	export TF_VAR_pg_port=$${PLATFORM_PG_PORT:-5433} && \
	export TF_VAR_kc_url=http://127.0.0.1:$${PLATFORM_KC_PORT:-8081} && \
	export TF_VAR_minio_server=127.0.0.1:$${PLATFORM_MINIO_PORT:-9002} && \
	export TF_VAR_redis_port=$${PLATFORM_REDIS_PORT:-6380} && \
	export TF_VAR_litellm_url=http://127.0.0.1:$${PLATFORM_LITELLM_PORT:-4001} && \
	export TF_VAR_pg_superuser=$$PLATFORM_PG_SUPERUSER && \
	export TF_VAR_kc_admin_user=$$PLATFORM_KC_ADMIN_USER && \
	export TF_VAR_minio_root_user=$$PLATFORM_MINIO_ROOT_USER && \
	cd terraform && terraform apply -auto-approve
	@echo ""
	@echo "✓ All Terraform modules applied"

tf-output: ## Show Terraform outputs: make tf-output PROJECT=cue
	$(TF) output -json | python3 -c "import json,sys; [print(f'{k}: {v[\"value\"]}') for k,v in json.load(sys.stdin).items() if not v.get('sensitive')]"

# ─── Database admin shells ────────────────────────────────────────────────────

shell-postgres: ## Connect to platform-postgres as superuser
	docker exec -it platform-postgres psql -U platform -d postgres

shell-postgres-%: ## Connect to platform-postgres as a project role: make shell-postgres-cue
	docker exec -it platform-postgres psql -U $* -d $*

shell-redis: ## Connect to platform-redis CLI
	docker exec -it platform-redis redis-cli

# ─── Migration ────────────────────────────────────────────────────────────────

migrate-postgres: ## Migrate Postgres from Cue private → platform (interactive, safe)
	bash scripts/migrate-postgres.sh

migrate-keycloak: ## Migrate Keycloak realm from Cue private → platform (with users)
	bash scripts/migrate-keycloak.sh

migrate-minio: ## Mirror MinIO buckets from Cue private → platform (zero-downtime)
	bash scripts/migrate-minio.sh

migrate-all: ## Run all three migrations in the correct order
	@echo "Step 1/3: Postgres"
	$(MAKE) migrate-postgres
	@echo ""
	@echo "Step 2/3: Keycloak"
	$(MAKE) migrate-keycloak
	@echo ""
	@echo "Step 3/3: MinIO"
	$(MAKE) migrate-minio

# ─── Backups (nightly pg_dump → MinIO) ────────────────────────────────────────

backup-now: ## Run a logical backup immediately (in addition to the 03:00 UTC cron)
	docker compose exec platform-backup /opt/backup/backup.sh

backup-list: ## List logical dumps currently in MinIO platform-backups bucket
	docker compose exec platform-backup mc ls --recursive platform/platform-backups/postgres/

backup-logs: ## Tail platform-backup logs (most recent cron run)
	docker compose logs --tail=200 platform-backup

restore-drill: ## Cold-restore latest logical dump for a DB into a scratch container: make restore-drill DB=cue
	bash scripts/restore-drill.sh $(DB)

# ─── WAL archiving + PITR ────────────────────────────────────────────────────

wal-status: ## Show pg_stat_archiver for both PG servers (archived/failed counters)
	@echo "── platform-postgres ──"
	@docker compose exec platform-postgres psql -U $${PLATFORM_PG_SUPERUSER:-platform} -d postgres \
		-c "SELECT archived_count, failed_count, last_archived_time, last_failed_time, last_failed_wal FROM pg_stat_archiver;"
	@echo "── platform-keycloak-postgres ──"
	@docker compose exec platform-keycloak-postgres psql -U $${PLATFORM_KC_DB_USER:-keycloak} -d keycloak \
		-c "SELECT archived_count, failed_count, last_archived_time, last_failed_time, last_failed_wal FROM pg_stat_archiver;"

wal-list: ## List wal-g backups (base backups, not WAL segments) for both clusters
	@echo "── platform-postgres ──"
	@docker compose exec platform-postgres su postgres -c "wal-g backup-list" || true
	@echo "── platform-keycloak-postgres ──"
	@docker compose exec platform-keycloak-postgres su postgres -c "wal-g backup-list" || true

wal-base-backup: ## Run an immediate base backup of platform-postgres (in addition to weekly cron)
	docker compose exec platform-postgres /opt/wal-g/base-backup.sh

wal-base-backup-keycloak: ## Run an immediate base backup of platform-keycloak-postgres
	docker compose exec platform-keycloak-postgres /opt/wal-g/base-backup.sh

wal-logs: ## Tail /var/log/wal-g.log on platform-postgres (base-backup history)
	docker compose exec platform-postgres tail -200 /var/log/wal-g.log

wal-restore-drill: ## PITR drill: restore from MinIO into scratch container. make wal-restore-drill [CLUSTER=postgres|keycloak] [PITR='YYYY-MM-DD HH:MM:SS UTC']
	bash scripts/wal-restore-drill.sh $(CLUSTER) "$(PITR)"

# ─── Alerting (Week 3) ────────────────────────────────────────────────────────

alerts-status: ## Show current alert states (firing, pending, inactive)
	@docker compose exec platform-prometheus wget -qO- 'http://localhost:9090/api/v1/alerts' \
		| python3 -m json.tool 2>/dev/null || \
		docker compose exec platform-prometheus wget -qO- 'http://localhost:9090/api/v1/alerts'

alerts-rules: ## Show active rule groups + thresholds
	@docker compose exec platform-prometheus wget -qO- 'http://localhost:9090/api/v1/rules' \
		| python3 -m json.tool 2>/dev/null || \
		docker compose exec platform-prometheus wget -qO- 'http://localhost:9090/api/v1/rules'

alerts-reload: ## Hot-reload prometheus rules after editing infra/prometheus/rules/*.yml
	curl -fsS -X POST http://localhost:$${PLATFORM_PROMETHEUS_PORT:-9091}/-/reload && echo "prometheus reloaded"

alerts-am-reload: ## Hot-reload alertmanager config (after editing alertmanager.yml.tmpl + bouncing the container — see runbook)
	docker compose restart platform-alertmanager

alerts-test: ## Fire a synthetic test alert through the full pipeline (renders alertmanager → email/SMS)
	@curl -fsS -X POST -H 'Content-Type: application/json' \
		http://localhost:$${PLATFORM_ALERTMANAGER_PORT:-9094}/api/v2/alerts \
		-d '[{"labels":{"alertname":"TestAlert","severity":"warning","service":"test"},"annotations":{"summary":"test alert from make alerts-test","description":"if you got this you have working alerting"},"startsAt":"'$$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}]' \
		&& echo "fired — expect email within 30s"

alerts-silence: ## Create a 1h silence by alertname: make alerts-silence ALERT=APIHighErrorRate
	@curl -fsS -X POST -H 'Content-Type: application/json' \
		http://localhost:$${PLATFORM_ALERTMANAGER_PORT:-9094}/api/v2/silences \
		-d '{"matchers":[{"name":"alertname","value":"$(ALERT)","isRegex":false}],"startsAt":"'$$(date -u +%Y-%m-%dT%H:%M:%SZ)'","endsAt":"'$$(date -u -d "+1 hour" +%Y-%m-%dT%H:%M:%SZ)'","createdBy":"$(USER)","comment":"silenced via make alerts-silence"}'

# ─── Utilities ────────────────────────────────────────────────────────────────

backups-ls: ## List migration backup files (local; from migrate-*.sh scripts)
	@ls -lh backups/ 2>/dev/null || echo "No backups yet (backups/ directory empty or missing)"

clean-backups: ## ⚠ Delete LOCAL migration backups older than 7 days
	find backups/ -mtime +7 -delete && echo "Old backups removed."
