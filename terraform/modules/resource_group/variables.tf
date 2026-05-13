variable "name" {
  description = "Resource Group name (e. g. rg-app-lab-kc)"
  type        = string

  validation {
    condition     = can(regex("^rg-", var.name))
    error_message = "Resource Group name must start with 'rg-'."
  }
}

variable "location" {
  description = "Azure region (e.g. koreacentral)"
  type        = string
  default     = "koreacentral"
}

variable "tags" {
  description = "Tags to apply to the resource group"
  type        = map(string)
  default = {
    "created_by" = "Terraform"
  }
}
