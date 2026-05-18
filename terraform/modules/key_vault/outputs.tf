output "id" {
  description = "Key Vault resource ID - role assignment scope에 사용"
  value       = azurerm_key_vault.this.id
}

output "name" {
  description = "Key Vault name - App Setting의 @Microsoft.KeyVault(VaultName=...) 에 사용"
  value       = azurerm_key_vault.this.name
}

output "vault_uri" {
  description = "https://<name>.vault.azure.net/"
  value       = azurerm_key_vault.this.vault_uri
}