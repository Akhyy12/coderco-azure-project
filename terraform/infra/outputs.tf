output "unleash_url" {
  value = "https://${azurerm_container_app.unleash.ingress[0].fqdn}"
}
