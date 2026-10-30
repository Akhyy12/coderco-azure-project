
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 5.0.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# Existing Resource Group
data "azurerm_resource_group" "example" {
  name = "rg-omer-dev"
}

# Existing Azure Container Registry
data "azurerm_container_registry" "example" {
  name                = "omerdev2030"
  resource_group_name = data.azurerm_resource_group.example.name
}

# Container Apps Environment
resource "azurerm_container_app_environment" "main" {
  name                = "omer-container-env"
  location            = data.azurerm_resource_group.example.location
  resource_group_name = data.azurerm_resource_group.example.name

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

# Managed Identity
resource "azurerm_user_assigned_identity" "main" {
  name                = "omer-container-identity"
  location            = data.azurerm_resource_group.example.location
  resource_group_name = data.azurerm_resource_group.example.name
}

# Allow Managed Identity to pull images from ACR
resource "azurerm_role_assignment" "acr_pull" {
  scope                = data.azurerm_container_registry.example.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.main.principal_id
  principal_type       = "ServicePrincipal"
}

# Azure Container App
resource "azurerm_container_app" "main" {
  name                         = "omer-container-app"
  resource_group_name          = data.azurerm_resource_group.example.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"
  workload_profile_name = "Consumption"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.main.id]
  }

  registry {
    server   = data.azurerm_container_registry.example.login_server
    identity = azurerm_user_assigned_identity.main.id
  }

  template {
    container {
      name   = "flask-app"
      image  = "${data.azurerm_container_registry.example.login_server}/coderco-azure-project:v1"
      cpu    = 0.25
      memory = "0.5Gi"
    }

    min_replicas = 0
    max_replicas = 1
  }

  ingress {
    external_enabled           = true
    target_port                = 3000
    allow_insecure_connections = false

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  depends_on = [azurerm_role_assignment.acr_pull]
}

# Outputs
output "resource_group_id" {
  value = data.azurerm_resource_group.example.id
}

output "login_server" {
  value = data.azurerm_container_registry.example.login_server
}

output "container_app_url" {
  value = "https://${azurerm_container_app.main.ingress[0].fqdn}"
}
