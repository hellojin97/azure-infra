output "subscription_id" {
  description = "Currently authenticated Azure subscription ID"
  value       = data.azurerm_subscription.current.subscription_id
}

output "subscription_name" {
  description = "Currently authenticated Azure subscription name"
  value       = data.azurerm_subscription.current.display_name
}

output "client_object_id" {
  description = "Object ID of the principal Terraform is running as"
  value       = data.azurerm_client_config.current.object_id
}

output "resource_group_id" {
  description = "ID of the application resource group"
  value       = module.rg_app.id
}

output "resource_group_name" {
  description = "Name of the application resource group"
  value       = module.rg_app.name
}