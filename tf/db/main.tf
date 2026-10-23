terraform {
  required_version = ">= 1.16.0"
  required_providers {
    mssql = {
      source  = "muecahit94/mssql"
      version = "~> 1.8" # Current release: 1.8.2
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
  }
}

# Generate a strong password for the isolated 'todo-app' user
resource "random_password" "db_password" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_+[]<>:?"
}

# -----------------------------------------------------------------------------
# Infra Outputs (RDS instance created by ../infra)
# -----------------------------------------------------------------------------
data "terraform_remote_state" "infra" {
  backend = "local"
  config = {
    path = "../infra/terraform.tfstate"
  }
}

locals {
  infra = data.terraform_remote_state.infra.outputs
}

# -----------------------------------------------------------------------------
# SQL Server Configuration: Isolated 'todo-app' User & Empty DB for EF Core
# -----------------------------------------------------------------------------
provider "mssql" {
  hostname = local.infra.db_address
  port     = local.infra.db_port
  sql_auth {
    username = local.infra.db_admin_username
    password = local.infra.db_admin_password
  }
}

# 1. Create the server-level login for 'todo-app'
resource "mssql_sql_login" "todo_app" {
  name     = "todo_app_user"
  password = random_password.db_password.result
}

# 2. Create the empty database for 'todo-app'
resource "mssql_database" "todo_db" {
  name = "TodoAppDB"
}

# 3. Grant 'todo-app' full control of its database. RDS does not let the
#    master user hand over database ownership to another login.
resource "mssql_sql_user" "todo_app" {
  database_name = mssql_database.todo_db.name
  name          = mssql_sql_login.todo_app.name
  login_name    = mssql_sql_login.todo_app.name
  roles         = ["db_owner"]
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "connection_string_ef_core" {
  description = "EF Core / .NET SqlClient connection string for todo-app"
  value       = "Server=${local.infra.db_address},${local.infra.db_port};Database=${mssql_sql_user.todo_app.database_name};User Id=${mssql_sql_login.todo_app.name};Password=${random_password.db_password.result};Encrypt=True;TrustServerCertificate=True;"
  sensitive   = true
}
