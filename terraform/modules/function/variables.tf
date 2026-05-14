variable "name" {
  description = "Function App name (e.g. func-app-lab-kc). Globally unique within Azure."
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "storage_account_name" {
  description = "Storage account name. 3-24 chars, lowercase leeters/numbers only, globally unique."
  type = string

  validation {
    condition = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "Must be 3-24 lowercase letters/numbers."
  }
}

variable "python_version" {
  description = "Python runtime version"
  type        = string
  default     = "3.11"

  validation {
    condition     = contains(["3.10", "3.11", "3.12"], var.python_version)
    error_message = "Supported: 3.10, 3.11, 3.12."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}