output "keyvault_url" {
  value = azurerm_key_vault.keyvault-ca.vault_uri
}

output "keyvault_name" {
  value = azurerm_key_vault.keyvault-ca.name
}