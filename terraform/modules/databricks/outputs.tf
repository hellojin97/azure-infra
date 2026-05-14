output "id" {
  description = "Workspace resource ID"
  value       = azurerm_databricks_workspace.this.id
}

output "workspace_url" {
  description = "URL to access the workspace UI"
  value       = azurerm_databricks_workspace.this.workspace_url
}

output "workspace_id" {
  description = "Numeric workspace ID (used by Databricks REST API)"
  value       = azurerm_databricks_workspace.this.workspace_id
}

output "managed_resource_group_id" {
  description = "ID of the managed resource group Databricks created"
  value       = azurerm_databricks_workspace.this.managed_resource_group_id
}