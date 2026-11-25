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