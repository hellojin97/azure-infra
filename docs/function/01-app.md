# Azure Function: Linux Python Consumption Plan

Azure Function App을 Terraform 모듈로 만드는 가이드 — Linux + Python + Y1 Consumption(서버리스) 조합.

이 문서를 읽기 전에 아래가 끝나있어야 합니다:

- [01-azure-bootstrap.md](../01-azure-bootstrap.md) — Azure 인증, state backend
- [02-terraform-skeleton.md](../02-terraform-skeleton.md) — Terraform 코드 골격
- [03-github-actions.md](../03-github-actions.md) — CI/CD 파이프라인
- 적어도 하나의 모듈 (예: `modules/resource_group/`)을 만들어 본 경험

---

## 핵심: 모듈 하나에 4개 리소스가 들어가는 이유

Function App 한 개가 정상 동작하려면 4개 리소스가 같이 살아야 합니다:

```text
modules/function/
   ├─ Storage Account     (런타임 state, trigger 메타데이터, 코드 zip 등)
   ├─ App Service Plan    (호스팅 환경 — Y1 Consumption)
   ├─ Application Insights (로그/메트릭/추적)
   └─ Linux Function App  (실제 함수)
```

**모듈 = "기능 1단위"** 원칙. 4개 모듈로 쪼개면 호출 측이 매번 4번 module 블록을 써야 해서 시끄러움. 하나로 묶음.

호스팅 plan / OS / 런타임 결정 사항:

| 결정 | 선택 | 이유 |
|---|---|---|
| Hosting plan | **Consumption (Y1)** | 서버리스, 실행한 만큼만 과금. 학습/소규모에 최적. |
| OS | **Linux** | Python 런타임 위해 필수 (Windows는 .NET/Node/PowerShell만) |
| Runtime | **Python 3.11** | 데이터 작업/Databricks 연동 등에 자주 쓰임 |
| Identity | **System-Assigned MI** | 다른 Azure 리소스(ADLS, Key Vault 등)에 RBAC 부여하기 위함 |

---

## 사전 확인: Resource Providers

```bash
for ns in Microsoft.Web Microsoft.Storage Microsoft.Insights; do
  echo -n "$ns: "
  az provider show --namespace "$ns" --query "registrationState" -o tsv
done
```

전부 `Registered` 면 OK. 안 됐으면:

```bash
az provider register --namespace Microsoft.Web
az provider register --namespace Microsoft.Storage
az provider register --namespace Microsoft.Insights
```

---

## 모듈 구조

```text
terraform/
├── main.tf              ← 수정: function module 호출
└── modules/
    └── function/        ← NEW
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

```bash
mkdir -p terraform/modules/function
```

---

## 1) `modules/function/variables.tf`

```hcl
variable "name" {
  description = "Function App name (e.g. func-app-lab-kc). Globally unique within Azure."
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "storage_account_name" {
  description = "Storage account name. 3-24 chars, lowercase letters/numbers only, globally unique."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
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
```

### 왜 `storage_account_name`을 별도 변수로

Storage Account는 까다로운 제약이 있습니다:

- 하이픈 불가
- 최대 24자
- 전세계 unique

`func-app-lab-kc` 같은 Function 이름에서 자동 derive하기 까다로워서 호출 측에서 명시적으로 넘기는 게 깔끔.

### `python_version` 선택

| 버전 | 상태 | 비고 |
|---|---|---|
| 3.10 | 지원 | EOL 임박 (2026년) |
| **3.11** | 권장 | 안정 |
| 3.12 | 지원 | 최신, 일부 라이브러리 호환성 확인 필요 |

---

## 2) `modules/function/main.tf`

```hcl
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
```

### 줄별 짚기

#### Storage Account

- `Standard_LRS`: 가장 저렴. Function 런타임용이라 충분.
- `min_tls_version = "TLS1_2"`: 보안 best practice.

#### App Service Plan

- `os_type = "Linux"` + `sku_name = "Y1"` = **Linux Consumption Plan**.
- 매 분당 max 200 instances까지 자동 확장. idle 시 0 (idle 비용 없음).
- 다른 SKU 옵션:
  - `EP1`/`EP2`/`EP3` — Premium (pre-warmed, VNet integration)
  - `B1`/`S1`/`P1v3` — Dedicated App Service Plan
  - `FC1` — Flex Consumption (newer, cold start 개선)

#### Function App

- **`storage_account_access_key`**: 런타임이 storage에 access할 access key.
  - Best practice는 Managed Identity로 가는 거지만 (Y1에서도 가능) 첫 시도는 access key가 단순.
  - 운영 단계에선 MI로 옮기길 권장 — `app_settings`에 `AzureWebJobsStorage__credential = "managedidentity"` 패턴.
- **`application_stack { python_version = ... }`**: Python 런타임 명시. (Linux에선 Python/Node/Java/.NET 등 한 가지만)
- **`application_insights_*`**: Function의 stdout/stderr, exception, dependency call 등이 자동 수집되어 App Insights로 흐름.
- **`identity { type = "SystemAssigned" }`**: System-Assigned Managed Identity 활성화.
  - Function이 다른 Azure 리소스 접근할 때 사용 (ADLS read, Key Vault secret 등)
  - 활성화는 무료, 안 켜두면 나중에 reattach가 번거로움

### 안 쓴 옵션 (default로 두는 것들)

| 옵션 | Default | 언제 명시 |
|---|---|---|
| `public_network_access_enabled` | true | private endpoint 쓸 때 |
| `app_settings` | `{}` | 함수 코드용 환경변수 (DB 연결 정보 등) |
| `auth_settings_v2` | 없음 | Easy Auth (AAD 통한 사용자 인증) |
| `cors` | 없음 | 브라우저에서 직접 호출할 때 |
| `client_certificate_mode` | "Required" | mTLS 인증 |

운영 단계 가면서 하나씩 명시하면 됨.

---

## 3) `modules/function/outputs.tf`

```hcl
output "id" {
  value = azurerm_linux_function_app.this.id
}

output "name" {
  value = azurerm_linux_function_app.this.name
}

output "default_hostname" {
  description = "Function App URL (e.g. func-app-lab-kc.azurewebsites.net)"
  value       = azurerm_linux_function_app.this.default_hostname
}

output "principal_id" {
  description = "System-assigned Managed Identity object ID — use for granting RBAC roles"
  value       = azurerm_linux_function_app.this.identity[0].principal_id
}

output "storage_account_name" {
  value = azurerm_storage_account.func.name
}

output "application_insights_id" {
  value = azurerm_application_insights.func.id
}
```

### 가장 자주 쓰게 될 outputs

- **`default_hostname`** — `https://${default_hostname}/api/...` 형태로 함수 호출. Apply 끝나면 바로 가져다 쓸 URL.
- **`principal_id`** — Function의 Managed Identity object ID. ADLS에 RBAC 부여할 때 이 값을 `--assignee-object-id`로 넘김.

예시 — Function이 ADLS의 Storage Blob Data Reader가 되게:

```bash
az role assignment create \
  --role "Storage Blob Data Reader" \
  --assignee-object-id "$(terraform output -raw function_principal_id)" \
  --assignee-principal-type ServicePrincipal \
  --scope "/subscriptions/.../storageAccounts/<adls>"
```

---

## 4) Root `terraform/main.tf` — 모듈 호출

```hcl
module "function" {
  source = "./modules/function"

  name                 = "func-app-lab-kc"
  storage_account_name = "stfuncapplabkc01"   # 본인 unique한 값으로
  resource_group_name  = module.rg_app.name
  location             = module.rg_app.location

  tags = {
    environment = "lab"
    managed_by  = "terraform"
    owner       = "hjkim"
  }
}
```

### `storage_account_name`은 본인 값으로

- 전세계 unique 강제. 처음 시도 후 충돌 나면 뒤에 숫자/글자 바꿔 retry.
- 패턴: `st<purpose><env><region><suffix>` — 예: `stfuncapplabkc01`
- 너무 짧으면 충돌 잘 남, 24자 한도 안에서 식별 가능하게.

---

## 5) (선택) Root `outputs.tf`

```hcl
output "function_url" {
  description = "Function App URL"
  value       = "https://${module.function.default_hostname}"
}

output "function_principal_id" {
  description = "Function MI object ID — for RBAC assignments"
  value       = module.function.principal_id
}
```

---

## PR → 머지 → Apply 흐름

```bash
cd /Users/dawn/azure-infra
git checkout main && git pull
git checkout -b feat/add-function

# (위 파일들 작성)

# 모듈 추가했으니 init 다시
cd terraform
terraform init \
  -backend-config="resource_group_name=$TFSTATE_RG" \
  -backend-config="storage_account_name=$TFSTATE_SA" \
  -backend-config="container_name=$TFSTATE_CONTAINER" \
  -backend-config="key=terraform.tfstate"

terraform fmt -recursive
terraform validate
terraform plan
# 기대: Plan: 4 to add  (storage, asp, appi, function app)

cd ..
git add terraform/
git commit -m "Add function module with Linux Python Consumption plan"
git push -u origin feat/add-function
gh pr create --fill
```

### Apply 후 확인

```bash
# Function App 정보
az functionapp show \
  -n "func-app-lab-kc" \
  -g "rg-app-lab-kc" \
  --query "{name:name, state:state, host:defaultHostName, runtime:siteConfig.linuxFxVersion}" -o table

# URL로 호출 (아직 함수 코드 없으니 default page)
curl -i "https://$(terraform -chdir=terraform output -raw function_url | sed 's|https://||')"

# 또는 브라우저로
open "$(terraform -chdir=terraform output -raw function_url)"
```

함수 코드 안 배포한 상태라 default landing page만 뜹니다 — **Terraform의 영역은 인프라까지**, 코드 배포는 별도 (zip deploy / GitHub Actions deploy / VS Code deploy 등).

---

## 자주 만나는 에러

### `StorageAccountAlreadyTaken`

→ Storage Account 이름이 다른 사람이 이미 사용 중. `storage_account_name`을 다른 값으로.

### `Cannot find SKU 'Y1' in region`

→ 일부 신규/소규모 리전은 Y1 미지원. Korea Central은 OK. East US, West Europe 등 메이저 리전은 모두 지원.

### `The runtime python is not supported on Windows`

→ Windows OS에서 Python 함수 만들려고 해서. `os_type = "Linux"` 확인.

### Apply는 됐는데 Function이 시작 안 됨

→ Function App 만든 직후 자가 진단/콜드스타트로 1-2분 정도 시간 필요. `az functionapp show`의 `state`가 `Running`인지 확인. App Insights에서 startup 로그 확인.

### `AzureWebJobsStorage` 관련 에러

→ Storage Account가 만들어지기 전에 Function App이 생성되려 함 (드물지만). Terraform이 자동으로 의존성 잡아주지만, 만약 발생하면 `depends_on = [azurerm_storage_account.func]`을 명시.

---

## 비용 (Y1 Consumption)

거의 무료에 가까움:

- **Function 실행**: 처음 **1M executions/월 + 400K GB-seconds 무료**
- **Storage**: 한 달 몇 센트 (실행 기록 등 메타데이터)
- **Application Insights**: 처음 **5 GB/월 무료**, 이후 ~$2.30/GB

학습 용도로는 사실상 무과금. 프로덕션 워크로드라면 트래픽 보고 EP1/Premium으로 갈아탈 시점 판단.

---

## 다음 단계

- [02-deploy-code.md](02-deploy-code.md) (예정) — HTTP trigger Hello World 코드 배포 (zip deploy / GitHub Actions)
- [03-managed-identity-rbac.md](03-managed-identity-rbac.md) (예정) — Function MI를 ADLS/Key Vault에 RBAC 부여
- [04-private-endpoint.md](04-private-endpoint.md) (예정) — Premium 으로 옮기고 VNet integration + private endpoint
