data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

# Resource Group
module "rg_app" {
  source = "./modules/resource_group"

  name     = "rg-dataplay-lab-kc"
  location = "koreacentral"

  tags = {
    environment = "LAB"
    managed_by  = "Terraform"
  }
}

# Databricks Workspace
module "databricks" {
  source = "./modules/databricks"

  name                = "dbw-dataplay-lab-kc"
  resource_group_name = module.rg_app.name
  location            = module.rg_app.location
  sku                 = "premium"

  tags = {
    environment = "LAB"
    managed_by  = "Terraform"
    type        = "Premium"
  }
}

# Azure Functions
module "function" {
  source = "./modules/function"

  name                 = "func-dataplay-lab-kc"
  storage_account_name = "stfuncapplabkc01" # 본인 unique한 값으로
  resource_group_name  = module.rg_app.name
  location             = module.rg_app.location

  app_settings = {
    DISCORD_WEBHOOK_URL = var.discord_webhook_url
  }

  tags = {
    environment = "LAB"
    managed_by  = "Terraform"
  }
}

# Key Vault
module "key_vault" {
  source = "./modules/key_vault"

  name                = "kv-dataplay-lab-kc"
  resource_group_name = module.rg_app.name
  location            = module.rg_app.location
  tenant_id           = data.azurerm_client_config.current.tenant_id

  tags = {
    environment = "LAB",
    managed_by  = "Terraform"
  }
}

# Function App MI에 secret 읽기 권한
# - App Setting의 @Microsoft.KeyVault(...) 참조 resolve에 필요
# - 이 role assignment가 app setting 변경보다 먼저 존재해야 resolve 성공
resource "azurerm_role_assignment" "kv_func_secrets_user" {
  scope                = module.key_vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.function.principal_id
}
