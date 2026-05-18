resource "azurerm_key_vault" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = var.tenant_id

  sku_name = "standard"

  # RBAC 모드 - legacy access policy 대신 azurerm_role_assignment로 권한 부여
  rbac_authorization_enabled = true

  # lab 환경: destroy/recreate 시 이름 재사용 빠르게 (기본 90일은 너무 김)
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  tags = var.tags
}