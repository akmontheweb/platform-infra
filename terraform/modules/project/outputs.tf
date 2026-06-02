output "database_url" {
  description = "Async SQLAlchemy DATABASE_URL for this project"
  value       = "postgresql+asyncpg://${var.project_name}:${random_password.pg_password.result}@platform-postgres:5432/${var.project_name}"
  sensitive   = true
}

output "broadcaster_url" {
  description = "Sync PostgreSQL URL for broadcaster/LISTEN-NOTIFY"
  value       = "postgresql://${var.project_name}:${random_password.pg_password.result}@platform-postgres:5432/${var.project_name}"
  sensitive   = true
}

output "redis_url" {
  description = "Redis URL with assigned DB number"
  value       = "redis://platform-redis:6379/${var.redis_db}"
}

output "keycloak_realm" {
  value = var.project_name
}

output "keycloak_client_secret" {
  value     = random_password.kc_client_secret.result
  sensitive = true
}

output "minio_access_key" {
  value = minio_iam_service_account.project.access_key
}

output "minio_secret_key" {
  value     = minio_iam_service_account.project.secret_key
  sensitive = true
}

output "litellm_api_key" {
  value     = local.litellm_key
  sensitive = true
}

output "env_file_path" {
  description = "Path to the generated .env.platform file"
  value       = local_file.project_env.filename
}
