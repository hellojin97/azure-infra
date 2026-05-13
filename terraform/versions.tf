terraform {
  #   코드를 돌리려면 Terraform CLI가 1.9.0 이상이어야 한다는 제약. 팀원/CI가 너무 옛날 버전 쓰는 걸 막아줌. 2026년 기준 최신은 1.10.x.  
  required_version = ">= 1.9.0"

  # HashiCorp 공식 Azure provider
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>4.0"
    }
  }
}
