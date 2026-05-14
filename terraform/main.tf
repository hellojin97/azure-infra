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