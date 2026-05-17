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