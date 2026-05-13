provider "azurerm" {
  # zurerm provider가 필수로 요구하는 빈 블록. 안에 옵션 넣어서 동작 변경 가능 
  # (예: resource_group { prevent_deletion_if_contains_resources = false }). 일단 비워둠.
  features {}
  use_oidc = true # GH Actions에서 발급받은 토큰을 자동으로 사용해서 인증.
}