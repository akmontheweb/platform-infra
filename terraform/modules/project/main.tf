# =============================================================================
# modules/project — Provisions ONE project's full namespace on platform-infra
#
# Creates:
#   - PostgreSQL: database + role
#   - Keycloak: realm + backend-service client + app-client + project-claims scope
#   - MinIO: IAM user + access key + buckets
#   - LiteLLM: virtual key with monthly token budget
#   - Caddy: route snippet file for this project's domain
#   - Output: complete .env file for the project
# =============================================================================

terraform {
  required_providers {
    postgresql = { source = "cyrilgdn/postgresql" }
    keycloak   = { source = "mrparkers/keycloak" }
    minio      = { source = "aminueza/minio" }
    random     = { source = "hashicorp/random" }
    local      = { source = "hashicorp/local" }
    null       = { source = "hashicorp/null" }
  }
}

# ---------------------------------------------------------------------------
# Random credentials
# ---------------------------------------------------------------------------
resource "random_password" "pg_password" {
  length  = 32
  special = false
}

resource "random_password" "kc_client_secret" {
  length  = 48
  special = false
}

# ---------------------------------------------------------------------------
# PostgreSQL: role + database
# ---------------------------------------------------------------------------
resource "postgresql_role" "project" {
  name     = var.project_name
  login    = true
  password = random_password.pg_password.result
}

resource "postgresql_database" "project" {
  name              = var.project_name
  owner             = postgresql_role.project.name
  lc_collate        = "en_US.UTF-8"
  connection_limit  = 50
  allow_connections = true

  depends_on = [postgresql_role.project]
}

resource "postgresql_extension" "vector" {
  name     = "vector"
  database = postgresql_database.project.name

  depends_on = [postgresql_database.project]
}

# ---------------------------------------------------------------------------
# Keycloak: realm + clients + scope
# ---------------------------------------------------------------------------
resource "keycloak_realm" "project" {
  realm                    = var.project_name
  enabled                  = true
  display_name             = var.project_display_name
  access_token_lifespan    = "5m"
  sso_session_idle_timeout = "30m"
  sso_session_max_lifespan = "10h"
}

# Backend-service client (client credentials flow — for API service accounts)
resource "keycloak_openid_client" "backend_service" {
  realm_id                     = keycloak_realm.project.id
  client_id                    = "backend-service"
  name                         = "Backend Service"
  enabled                      = true
  access_type                  = "CONFIDENTIAL"
  service_accounts_enabled     = true
  direct_access_grants_enabled = false
  client_secret                = random_password.kc_client_secret.result

  depends_on = [keycloak_realm.project]
}

# App client (public SPA — browser login, PKCE)
resource "keycloak_openid_client" "app_client" {
  realm_id                     = keycloak_realm.project.id
  client_id                    = "app-client"
  name                         = "App Client"
  enabled                      = true
  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  valid_redirect_uris          = ["${var.app_base_url}/*"]
  web_origins                  = [var.app_base_url]

  depends_on = [keycloak_realm.project]
}

# project-claims scope + user mapper
resource "keycloak_openid_client_scope" "project_claims" {
  realm_id               = keycloak_realm.project.id
  name                   = "${var.project_name}-claims"
  description            = "Custom claims for ${var.project_name}"
  include_in_token_scope = true

  depends_on = [keycloak_realm.project]
}

resource "keycloak_openid_user_attribute_protocol_mapper" "project_attr" {
  realm_id         = keycloak_realm.project.id
  client_scope_id  = keycloak_openid_client_scope.project_claims.id
  name             = "project-attr"
  user_attribute   = "project"
  claim_name       = "project"
  claim_value_type = "String"
}

# ---------------------------------------------------------------------------
# MinIO: IAM user + access key + buckets
# ---------------------------------------------------------------------------
resource "minio_iam_user" "project" {
  name          = var.project_name
  force_destroy = false
}

resource "minio_iam_user_policy_attachment" "project" {
  user_name   = minio_iam_user.project.name
  policy_name = minio_iam_policy.project.id
}

resource "minio_iam_policy" "project" {
  name = "${var.project_name}-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:*"]
        Resource = [
          "arn:aws:s3:::${var.project_name}-*",
          "arn:aws:s3:::${var.project_name}-*/*"
        ]
      }
    ]
  })
}

resource "minio_s3_bucket" "images" {
  bucket = "${var.project_name}-images"
  acl    = "private"
}

resource "minio_s3_bucket" "docs" {
  bucket = "${var.project_name}-docs"
  acl    = "private"
}

resource "minio_iam_service_account" "project" {
  target_user = minio_iam_user.project.name
}

# ---------------------------------------------------------------------------
# LiteLLM: virtual key with budget
# ---------------------------------------------------------------------------
resource "null_resource" "litellm_key" {
  triggers = {
    project_name = var.project_name
    budget       = var.litellm_budget_tokens
  }

  provisioner "local-exec" {
    command = <<-EOT
      http_code=$(curl -s -o /tmp/litellm_resp_${var.project_name}.json \
        -w "%%{http_code}" \
        -X POST "${var.litellm_url}/key/generate" \
        -H "Authorization: Bearer ${var.litellm_master_key}" \
        -H "Content-Type: application/json" \
        -d '{
          "key_alias": "${var.project_name}",
          "max_budget": ${var.litellm_budget_tokens},
          "budget_reset_at": "monthly",
          "models": ["fast-model","balanced-model","vision-model","embedding","transcription-model"],
          "metadata": {"project": "${var.project_name}"}
        }')
      response=$(cat /tmp/litellm_resp_${var.project_name}.json 2>/dev/null)
      if [ "$http_code" = "200" ] && echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'key' in d" 2>/dev/null; then
        mv /tmp/litellm_resp_${var.project_name}.json /tmp/litellm_key_${var.project_name}.json
      else
        echo "ERROR: LiteLLM key generation failed. HTTP $http_code. Body: $response" >&2
        exit 1
      fi
    EOT
  }
}

data "local_file" "litellm_key_file" {
  filename   = "/tmp/litellm_key_${var.project_name}.json"
  depends_on = [null_resource.litellm_key]
}

locals {
  litellm_key_data = jsondecode(data.local_file.litellm_key_file.content)
  litellm_key      = local.litellm_key_data["key"]
}

# ---------------------------------------------------------------------------
# Caddy route snippet
# ---------------------------------------------------------------------------
resource "local_file" "caddy_route" {
  filename = "${path.module}/../../../infra/caddy/routes/${var.project_name}.caddy"
  content = templatefile("${path.module}/templates/caddy-route.tpl", {
    project_name = var.project_name
    domain       = var.domain
    api_port     = var.api_container_port
  })

  # Reload Caddy after writing the route
  provisioner "local-exec" {
    command = "docker exec platform-caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true"
  }
}

# ---------------------------------------------------------------------------
# Output: complete .env file for the project
# ---------------------------------------------------------------------------
resource "local_file" "project_env" {
  filename        = "${path.root}/../../${var.project_name}/.env.platform"
  file_permission = "0600"
  content = templatefile("${path.module}/templates/env.tpl", {
    project_name     = var.project_name
    domain           = var.domain
    pg_password      = random_password.pg_password.result
    pg_host          = "platform-postgres"
    pg_port          = 5432
    kc_realm         = var.project_name
    kc_client_secret = random_password.kc_client_secret.result
    minio_access_key = minio_iam_service_account.project.access_key
    minio_secret_key = minio_iam_service_account.project.secret_key
    redis_db         = var.redis_db
    litellm_key      = local.litellm_key
  })

  depends_on = [
    postgresql_database.project,
    keycloak_openid_client.backend_service,
    minio_iam_service_account.project,
    null_resource.litellm_key,
  ]
}
