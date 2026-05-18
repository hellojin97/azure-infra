variable "name" {
  description = "Key Vault name. 3-24자. 알파벳 시작, 알파벳/숫자/하이픈, globally unique"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$", var.name))
    error_message = "3-24자, 알파벳 시작, 알파벳/숫자/하이픈만, 끝은 영숫자."
  }
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tenant_id" {
  description = "AAD tenant ID - Key Vault 가 인증할 테넌트"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
