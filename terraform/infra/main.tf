resource "azurerm_resource_group" "main" {
  name     = "rg-unleash-app"
  location = "northeurope"
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-unleash-dev"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "apps" {
  name                 = "snet-apps"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.0.0/23"]

  delegation {
    name = "containerapps"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "db" {
  name                 = "snet-db"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]

  delegation {
    name = "postgres"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# ---------- 4b: PostgreSQL ----------

# Starkt lösenord som Terraform genererar (ingen människa skriver det)
resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "!#%*-_=+"
}

# Privat DNS: gör att apparna hittar databasen med namn, inte IP
resource "azurerm_private_dns_zone" "postgres" {
  name                = "unleash.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name
}

# Kopplar DNS-zonen till vårt VNet
resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "postgres-vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.main.id
  resource_group_name   = azurerm_resource_group.main.name
}

# Själva databasservern, i det privata subnätet
resource "azurerm_postgresql_flexible_server" "main" {
  name                          = "psql-omer-unleash-ne"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  version                       = "16"
  delegated_subnet_id           = azurerm_subnet.db.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false

  administrator_login    = "unleashadmin"
  administrator_password = random_password.db.result

  sku_name              = "B_Standard_B1ms" # minsta och billigaste nivån
  storage_mb            = 32768
  backup_retention_days = 7

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]

  lifecycle {
    ignore_changes = [zone] # Azure väljer zon själv, ignorera den
  }
}

# Databasen som Unleash ska använda
resource "azurerm_postgresql_flexible_server_database" "unleash" {
  name      = "unleash"
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# ---------- 4c: Key Vault ----------

# Info om dig som kör Terraform (tenant och ditt användar-ID)
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "main" {
  name                       = "kv-omer-unleash-ne"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true  # behörigheter styrs med roller
  purge_protection_enabled   = false # så att destroy och apply fungerar igen
  soft_delete_retention_days = 7
}

# Ger dig rätt att skriva hemligheter i Key Vault
resource "azurerm_role_assignment" "kv_me" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Databaslösenordet sparas i Key Vault
resource "azurerm_key_vault_secret" "db_password" {
  name         = "db-password"
  value        = random_password.db.result
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_role_assignment.kv_me]
}

# ---------- 5a: Container Registry ----------

resource "azurerm_container_registry" "main" {
  name                = "acrunleashdev"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = false
}


# ---------- 5c: Identitet och behörigheter ----------

# Apparnas "ID-kort"
resource "azurerm_user_assigned_identity" "apps" {
  name                = "id-unleash-apps"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

# Får HÄMTA images från ACR (inte pusha eller radera)
resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.apps.principal_id
}

# Får LÄSA hemligheter i Key Vault (inte skriva eller radera)
resource "azurerm_role_assignment" "kv_apps" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.apps.principal_id
}

# ---------- 5d: Container Apps Environment ----------

# Hit skickas apparnas loggar
resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-unleash-dev"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# "Huset" för apparna, i snet-apps
resource "azurerm_container_app_environment" "main" {
  name                       = "cae-unleash-dev"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  infrastructure_subnet_id   = azurerm_subnet.apps.id

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

# ---------- 5e: Unleash ----------

# Starkt lösenord för Unleash admin (ersätter unleash4all)
resource "random_password" "unleash_admin" {
  length  = 24
  special = false
}

# Hemlig del av API-nyckeln som Flask använder
resource "random_password" "unleash_token" {
  length  = 32
  special = false
}

resource "azurerm_key_vault_secret" "unleash_admin_password" {
  name         = "unleash-admin-password"
  value        = random_password.unleash_admin.result
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.kv_me]
}

# Hela nyckeln: projekt:miljö.hemlighet
resource "azurerm_key_vault_secret" "unleash_backend_token" {
  name         = "unleash-backend-token"
  value        = "default:development.${random_password.unleash_token.result}"
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.kv_me]
}

resource "azurerm_container_app" "unleash" {
  name                         = "ca-unleash"
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  # Appens ID-kort
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.apps.id]
  }

  # Hämtar imagen från ACR med ID-kortet, inget lösenord
  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.apps.id
  }

  # Hemligheter hämtas direkt från Key Vault med ID-kortet
  secret {
    name                = "db-password"
    key_vault_secret_id = azurerm_key_vault_secret.db_password.versionless_id
    identity            = azurerm_user_assigned_identity.apps.id
  }
  secret {
    name                = "admin-password"
    key_vault_secret_id = azurerm_key_vault_secret.unleash_admin_password.versionless_id
    identity            = azurerm_user_assigned_identity.apps.id
  }
  secret {
    name                = "backend-token"
    key_vault_secret_id = azurerm_key_vault_secret.unleash_backend_token.versionless_id
    identity            = azurerm_user_assigned_identity.apps.id
  }

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "unleash"
      image  = "${azurerm_container_registry.main.login_server}/unleash:v1"
      cpu    = 0.5
      memory = "1Gi"

      # Samma variabler som i docker-compose, men pekar på Azure
      env {
        name  = "DATABASE_HOST"
        value = azurerm_postgresql_flexible_server.main.fqdn
      }
      env {
        name  = "DATABASE_NAME"
        value = azurerm_postgresql_flexible_server_database.unleash.name
      }
      env {
        name  = "DATABASE_USERNAME"
        value = azurerm_postgresql_flexible_server.main.administrator_login
      }
      env {
        name        = "DATABASE_PASSWORD"
        secret_name = "db-password"
      }
      env {
        name  = "DATABASE_SSL"
        value = "true"
      }
      env {
        name        = "UNLEASH_DEFAULT_ADMIN_PASSWORD"
        secret_name = "admin-password"
      }
      env {
        name        = "INIT_BACKEND_API_TOKENS"
        secret_name = "backend-token"
      }

      # Azure kollar /health, samma endpoint som din Dockerfile
      liveness_probe {
        transport     = "HTTP"
        port          = 4242
        path          = "/health"
        initial_delay = 30
      }
      readiness_probe {
        transport = "HTTP"
        port      = 4242
        path      = "/health"
      }
    }
  }

  ingress {
    external_enabled           = true
    target_port                = 4242
    allow_insecure_connections = false

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  # Behörigheterna måste finnas innan appen försöker hämta image och hemligheter
  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.kv_apps,
  ]
}