terraform {
  required_version = ">= 1.6"

  required_providers {
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "~> 1.22"
    }
    keycloak = {
      source  = "mrparkers/keycloak"
      version = "~> 4.4"
    }
    minio = {
      source  = "aminueza/minio"
      version = "~> 2.3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# ---------------------------------------------------------------------------
# PostgreSQL provider — connects as superuser to create per-project DBs/roles
# ---------------------------------------------------------------------------
provider "postgresql" {
  host            = var.pg_host
  port            = var.pg_port
  database        = "postgres"
  username        = var.pg_superuser
  password        = var.pg_superpassword
  sslmode         = "disable"
  connect_timeout = 15
  superuser       = true
}

# ---------------------------------------------------------------------------
# Keycloak provider — admin credentials
# ---------------------------------------------------------------------------
provider "keycloak" {
  client_id = "admin-cli"
  username  = var.kc_admin_user
  password  = var.kc_admin_password
  url       = var.kc_url
}

# ---------------------------------------------------------------------------
# MinIO provider — root credentials
# ---------------------------------------------------------------------------
provider "minio" {
  minio_server   = var.minio_server
  minio_user     = var.minio_root_user
  minio_password = var.minio_root_password
  minio_ssl      = false
}
