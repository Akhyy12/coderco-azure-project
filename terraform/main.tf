terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}

  resource_provider_registrations = "none"
}

data "azurerm_resource_group" "main" {
  name = "rg-omer-dev"
}

data "azurerm_container_registry" "main" {
  name                = "omerdev2030"
  resource_group_name = data.azurerm_resource_group.main.name
}

data "azurerm_container_app_environment" "main" {
  name                = "omer-container-env"
  resource_group_name = data.azurerm_resource_group.main.name
}


resource "azurerm_container_app" "main" {
  name                         = "omer-container-app"
  resource_group_name          = data.azurerm_resource_group.main.name
  container_app_environment_id = data.azurerm_container_app_environment.main.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type = "UserAssigned"
    identity_ids = [
      "/subscriptions/a1b8a81f-c40a-45ef-8a68-59b7d2846e91/resourceGroups/rg-omer-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/omer-container-identity"
    ]
  }

  registry {
    server   = data.azurerm_container_registry.main.login_server
    identity = "/subscriptions/a1b8a81f-c40a-45ef-8a68-59b7d2846e91/resourceGroups/rg-omer-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/omer-container-identity"
  }

  template {
    container {
      name   = "flask-app"
      image  = "omerdev2030.azurecr.io/flask-app-v2:v1"
      cpu    = 0.25
      memory = "0.5Gi"
    }

    max_replicas = 1
  }

  lifecycle {
    ignore_changes = [
      template[0].container[0].image
    ]
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
}