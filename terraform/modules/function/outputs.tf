output "id" {
  value = azurerm_linux_function_app.this.id
}

output "name" {
  value = azurerm_linux_function_app.this.name
}

output "default_hostname" {
  description = "Function App URL (e.g. func-app-lab-kc.azurewebsites.net)"
  value       = azurerm_linux_function_app.this.default_hostname
}

output "principal_id" {
  description = "System-assigned Managed Identity object ID — use for granting RBAC roles"
  value       = azurerm_linux_function_app.this.identity[0].principal_id
}

output "storage_account_name" {
  value = azurerm_storage_account.func.name
}

output "application_insights_id" {
  value = azurerm_application_insights.func.id
}
