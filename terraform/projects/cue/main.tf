# =============================================================================
# Terraform project declaration for: Cue
#
# Run after `make up` to provision Cue's namespace on platform-infra:
#   cd platform-infra/terraform
#   terraform init
#   terraform apply -target=module.cue
#
# This creates an EMPTY target environment. Run migration scripts AFTER this.
# =============================================================================

module "cue" {
  source = "../../modules/project"

  project_name         = "cue"
  project_display_name = "Cue"
  domain               = var.domain
  app_base_url         = "http://${var.server_ip}:8888"
  redis_db             = 2   # DB 2 reserved for Cue
  litellm_budget_tokens = 5000000
  litellm_url          = var.litellm_url
  litellm_master_key   = var.litellm_master_key
  api_container_port   = 8000
}

output "cue_env_file" {
  description = "Path to generated Cue .env.platform file — copy values into Cue/.env after migration"
  value       = module.cue.env_file_path
}

output "cue_database_url" {
  value     = module.cue.database_url
  sensitive = true
}

output "cue_keycloak_client_secret" {
  value     = module.cue.keycloak_client_secret
  sensitive = true
}
