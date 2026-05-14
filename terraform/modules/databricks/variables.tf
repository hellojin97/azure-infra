variable "name" {
  description = "Databricks Workspace name(e.g. dbw-app-lab-kc)"
  type        = string
}

variable "resource_group_name" {
  description = "Resource Group to place the workspace in"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "sku" {
  description = "Workspace SKU (standard, premium, trial)"
  type        = string
  default     = "premium"

  validation {
    condition     = contains(["standard", "premium", "trial"], var.sku)
    error_message = "SKU must be on of: standard, premium, trial"
  }
}

variable "managed_resource_group_name" {
  description = "Optional custom name for the Databricks-managed RG. If null, Azure auto-names it."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tag applied to the workspace"
  type        = map(string)
  default     = {}
}