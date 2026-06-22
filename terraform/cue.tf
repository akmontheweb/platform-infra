# =============================================================================
# Cue project namespace — provisioned on platform-infra
# This file lives in the terraform/ root so providers from main.tf apply.
# =============================================================================

module "cue" {
  source = "./modules/project"

  project_name          = "cue"
  project_display_name  = "Cue"
  domain                = var.domain
  app_base_url          = "https://cue.${var.domain}"
  redis_db              = 2
  redis_password        = var.redis_password
  litellm_budget_tokens = 5000000
  litellm_url           = var.litellm_url
  litellm_master_key    = var.litellm_master_key
  api_container_port    = 8000
}

output "cue_env_file" {
  description = "Path to generated .env.platform — merge into cue/.env after migration"
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

output "cue_minio_access_key" {
  value = module.cue.minio_access_key
}

output "cue_litellm_api_key" {
  value     = module.cue.litellm_api_key
  sensitive = true
}
