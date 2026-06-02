.PHONY: up down logs build ps shell-postgres shell-redis provision rollback help

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

# ─── Terraform ───────────────────────────────────────────────────────────────

tf-init: ## Initialize Terraform providers
	$(TF) init

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

# ─── Utilities ────────────────────────────────────────────────────────────────

backups-ls: ## List migration backup files
	@ls -lh backups/ 2>/dev/null || echo "No backups yet (backups/ directory empty or missing)"

clean-backups: ## ⚠ Delete backups older than 7 days
	find backups/ -mtime +7 -delete && echo "Old backups removed."
