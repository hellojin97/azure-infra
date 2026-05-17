# Storage Account — Function 런타임이 의존
resource "azurerm_storage_account" "func" {
  name                     = var.storage_account_name
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  tags = var.tags
}

# Application Insights — 로그/메트릭
resource "azurerm_application_insights" "func" {
  name                = "appi-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  application_type    = "web"

  tags = var.tags
}

# App Service Plan — Y1 = Consumption (서버리스)
resource "azurerm_service_plan" "func" {
  name                = "asp-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "Y1"

  tags = var.tags
}

# Linux Function App — 실제 함수 호스트
resource "azurerm_linux_function_app" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location

  storage_account_name       = azurerm_storage_account.func.name
  storage_account_access_key = azurerm_storage_account.func.primary_access_key
  service_plan_id            = azurerm_service_plan.func.id

  https_only = true

  app_settings = merge(
    {
      AzureWebJobsFeatureFlags = "EnableWorkerIndexing"
    },
    var.app_settings,
  )

  site_config {
    application_stack {
      python_version = var.python_version
    }
    application_insights_connection_string = azurerm_application_insights.func.connection_string
    application_insights_key               = azurerm_application_insights.func.instrumentation_key
  }

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}