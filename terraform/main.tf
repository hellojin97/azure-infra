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