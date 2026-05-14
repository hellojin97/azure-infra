# Databricks: Workspace 생성

Azure Databricks Workspace를 Terraform 모듈로 만드는 가이드.

이 문서를 읽기 전에 아래가 끝나있어야 합니다:
- [01-azure-bootstrap.md](../01-azure-bootstrap.md) — Azure 인증, state backend
- [02-terraform-skeleton.md](../02-terraform-skeleton.md) — Terraform 코드 골격
- [03-github-actions.md](../03-github-actions.md) — CI/CD 파이프라인
- 그리고 적어도 하나의 Resource Group 모듈 (`modules/resource_group/`)을 만들어 본 경험

---

## 핵심 개념: Databricks의 두 plane

Databricks는 작업이 **두 개의 다른 영역**에 걸쳐 있어서 처음 다룰 때 헷갈립니다:

| Plane | 다루는 객체 | 사용 Terraform Provider | 필요한 권한 |
|---|---|---|---|
| **Azure 리소스** | Workspace, Resource Group, Networking, Access Connector 등 | `hashicorp/azurerm` | Azure RBAC (Contributor 등) |
| **Databricks Account/Workspace** | Metastore, Catalog, Schema, Grants, Cluster Policy, User/SCIM 등 | `databricks/databricks` | Databricks Admin (Account Admin / Workspace Admin) |

이 문서는 **첫 번째 plane (Azure 리소스)** 만 다룹니다 — `azurerm_databricks_workspace`로 워크스페이스 자체를 만드는 부분.

두 번째 plane (Unity Catalog metastore 할당, catalog 생성, 권한 부여 등)은 별도 문서에서 다룹니다.

---

## 사전 확인: Resource Provider 등록

Azure는 구독별로 Resource Provider 등록이 필요합니다. Databricks RP가 등록 안 돼있으면 apply 시 에러가 납니다.

```bash
# 등록 상태 확인
az provider show --namespace Microsoft.Databricks --query "registrationState" -o tsv
# Registered 면 OK

# 안 됐으면 등록 (1~5분 소요)
az provider register --namespace Microsoft.Databricks
```

대부분 자동 등록되어 있지만, 새 구독이면 한 번 확인해 두면 시행착오를 줄입니다.

---

## 모듈 구조

```
terraform/
├── main.tf              ← 수정: databricks module 호출 추가
├── outputs.tf           ← 수정 (선택): workspace_url 노출
└── modules/
    ├── resource_group/
    └── databricks/      ← NEW
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

```bash
mkdir -p terraform/modules/databricks
```

---

## 1) `modules/databricks/variables.tf`

```hcl
variable "name" {
  description = "Databricks Workspace name (e.g. dbw-app-lab-kc)"
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
    error_message = "SKU must be one of: standard, premium, trial."
  }
}

variable "managed_resource_group_name" {
  description = "Optional custom name for the Databricks-managed RG. If null, Azure auto-names it."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to the workspace"
  type        = map(string)
  default     = {}
}
```

### 주목할 변수: `managed_resource_group_name`

Databricks workspace를 만들면 Azure가 **별도의 "managed Resource Group"** 을 자동 생성합니다 (워크스페이스 내부 인프라용 — VNet, NSG, 디스크 등). 사용자가 손대면 안 되고 Databricks가 관리합니다.

- `null`이면 Azure가 자동 이름 (예: `databricks-rg-dbw-app-lab-kc-xxx`)
- 명시하면 본인이 정한 이름. 같은 RG에서 워크스페이스 두 개 만들 일 있으면 unique 이름 강제 필요

처음엔 `null`로 두고 자동 이름 받는 게 무난.

### `sku` 선택 가이드

| SKU | 특징 | 언제 |
|---|---|---|
| `standard` | 기본 기능, 더 저렴 | 단순한 lab/dev |
| `premium` | Unity Catalog, RBAC, IP access list, audit log, Serverless | 운영 환경, Unity Catalog 쓸 거면 필수 |
| `trial` | 14일 무료 Premium | 짧은 평가용 |

⚠️ Workspace **생성 후 SKU 변경은 destroy + recreate**가 필요합니다 (replacement). 신중히 선택.

---

## 2) `modules/databricks/main.tf`

```hcl
resource "azurerm_databricks_workspace" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku

  managed_resource_group_name = var.managed_resource_group_name

  tags = var.tags
}
```

### 옵션을 안 쓴 이유 (default로 두는 것들)

이 리소스에는 옵션이 많지만 처음엔 default가 무난:

| 미설정 옵션 | Default 동작 | 언제 명시? |
|---|---|---|
| `public_network_access_enabled` | `true` (인터넷에서 접근 가능) | 사내망 only일 때 false + Private Endpoint |
| `customer_managed_key_enabled` | `false` | Key Vault로 CMK 쓸 때 |
| `infrastructure_encryption_enabled` | `false` | 이중 암호화 필요할 때 |
| `custom_parameters` (VNet injection) | 없음 — managed VNet 사용 | 자체 VNet에 워크스페이스 박을 때 |
| `network_security_group_rules_required` | `AllRules` | NPIP/serverless 환경 |

운영 단계 가면서 하나씩 명시하면 됨.

---

## 3) `modules/databricks/outputs.tf`

```hcl
output "id" {
  description = "Workspace resource ID"
  value       = azurerm_databricks_workspace.this.id
}

output "workspace_url" {
  description = "URL to access the workspace UI"
  value       = azurerm_databricks_workspace.this.workspace_url
}

output "workspace_id" {
  description = "Numeric workspace ID (used by Databricks REST API)"
  value       = azurerm_databricks_workspace.this.workspace_id
}

output "managed_resource_group_id" {
  description = "ID of the managed resource group Databricks created"
  value       = azurerm_databricks_workspace.this.managed_resource_group_id
}
```

### 각 output 용도

- **`workspace_url`**: apply 끝나면 콘솔에 출력돼서 바로 클릭으로 워크스페이스 접속. 가장 자주 봄.
- **`workspace_id`**: Databricks REST API 호출이나 `databricks/databricks` provider 쓸 때 필요한 숫자 ID.
- **`managed_resource_group_id`**: 자동 생성된 managed RG의 ID. 나중에 추가 권한이나 정책 걸 때 참조.

---

## 4) Root `terraform/main.tf` — 모듈 호출

```hcl
module "databricks" {
  source = "./modules/databricks"

  name                = "dbw-app-lab-kc"
  resource_group_name = module.rg_app.name
  location            = module.rg_app.location
  sku                 = "premium"

  tags = {
    environment = "lab"
    managed_by  = "terraform"
    owner       = "hjkim"
  }
}
```

### 모듈 간 의존성

```hcl
resource_group_name = module.rg_app.name
location            = module.rg_app.location
```

이 두 줄이 **모듈 간 의존성**을 만듭니다. Terraform이 자동으로 그래프를 그려서:

```
module.rg_app  ─create→  module.databricks
```

순서로 적용. RG 없으면 워크스페이스 못 만드니까 자연스러움. 명시적 `depends_on` 안 써도 됨.

---

## 5) (선택) Root `outputs.tf` 에 workspace URL 노출

```hcl
output "databricks_workspace_url" {
  description = "URL to log into Databricks"
  value       = "https://${module.databricks.workspace_url}"
}
```

Apply 끝나면 콘솔에 클릭 가능한 URL이 뜸.

---

## PR → 머지 → Apply 흐름

```bash
cd /Users/dawn/azure-infra
git checkout main && git pull
git checkout -b feat/add-databricks

# (위 파일들 작성)

# 모듈 추가했으니 init 다시!
cd terraform
terraform init \
  -backend-config="resource_group_name=$TFSTATE_RG" \
  -backend-config="storage_account_name=$TFSTATE_SA" \
  -backend-config="container_name=$TFSTATE_CONTAINER" \
  -backend-config="key=terraform.tfstate"

terraform fmt -recursive
terraform validate
terraform plan
# 기대: Plan: 1 to add  (workspace 한 개)

# commit + push + PR
cd ..
git add terraform/
git commit -m "Add databricks module and create dbw-app-lab-kc workspace"
git push -u origin feat/add-databricks
gh pr create --fill
```

### Apply 소요 시간

Databricks workspace 생성은 **5~10분** 정도 걸립니다. apply 워크플로우가 한참 도는 게 정상이니 끊지 마세요.

### Apply 후 확인

```bash
# 두 RG가 보여야 함 — 본인이 만든 RG + Databricks 자동 생성 managed RG
az group list --query "[?contains(name, 'lab')].name" -o table

# workspace 정보
az databricks workspace show \
  -n "dbw-app-lab-kc" \
  -g "rg-app-lab-kc" \
  --query "{name:name, sku:sku.name, url:workspaceUrl}" -o table

# state에 잡힌 거
cd terraform
terraform state list | grep databricks
# module.databricks.azurerm_databricks_workspace.this

# URL로 접속
terraform output databricks_workspace_url
```

URL 클릭 → Azure AD SSO로 로그인 → Databricks UI 진입.

---

## Workspace Type 이해하기 (Hybrid vs Classic)

워크스페이스 만들고 Azure Portal이나 Account Console에서 보면 **Workspace Type** 항목이 보입니다.

### 세 가지 type

| Type | 지원하는 컴퓨트 | 누가 호스팅 |
|---|---|---|
| **Classic** | Classic compute (전통적인 클러스터)만 | **본인 Azure 구독** (managed RG에 VM이 뜸) |
| **Hybrid** | Classic + **Serverless** 둘 다 | Classic은 본인 구독, Serverless는 Databricks 구독 |
| **Serverless-only** | Serverless만 | 전부 Databricks 구독 (Azure에선 거의 안 보임) |

### Classic vs Serverless 컴퓨트

**Classic compute**
- 클러스터/SQL warehouse 만들면 Databricks가 **본인 구독의 managed RG에 VM 배포**
- managed RG에 가서 보면 실제로 `Microsoft.Compute/virtualMachineScaleSets` 같은 게 보임
- 비용 = Azure VM 요금 + Databricks DBU 요금
- 시작 시간 = 분 단위

**Serverless compute**
- Serverless SQL warehouse, Serverless Jobs, Model Serving 같은 거
- VM이 본인 구독에 안 뜸 — Databricks가 자기 인프라에서 관리
- 비용 = DBU 요금만 (인프라 비용은 단가에 포함)
- 시작 시간 = 수 초

### 왜 Hybrid가 됐나

**Premium SKU**를 골랐기 때문입니다. Serverless는 Premium에서만 활성화 → **Premium = 자동 Hybrid**.

Standard SKU로 만들었으면 "Classic"으로 표시됩니다.

학습 단계에서는 의식적으로 신경 쓸 필요는 없고, 다만 Serverless는 cold start가 빠른 대신 일부 네트워크 격리(Private Endpoint 등) 옵션이 제한될 수 있다는 정도만 알아두면 됩니다.

---

## 비용 주의

- **Workspace 자체는 무료** (모든 SKU). 띄워둬도 과금 안 됨.
- **컴퓨트(클러스터/SQL warehouse) 띄우면 그때부터 과금**. Premium이 standard보다 약간 비쌈.
- 학습 끝나면:
  - 클러스터 auto-terminate 옵션 켜두기 (idle X분 후 자동 종료)
  - SQL warehouse는 사용 안 할 때 stop
  - Serverless는 자동으로 idle terminate 됨 (별도 설정 불필요)

---

## 자주 만나는 에러

### `The subscription is not registered to use namespace 'Microsoft.Databricks'`

→ Resource Provider 미등록. 위의 사전 확인 단계 참조.

### `Region is not supported for Workspace`

→ 일부 신규 리전은 Databricks 미지원. Korea Central은 OK. East US, West US, Southeast Asia 등 메이저 리전은 모두 지원.

### `SKU change requires recreation`

→ standard ↔ premium 변경은 destroy + recreate 필요. plan에 `# forces replacement` 라고 표시됨. 워크스페이스 안에 있는 데이터/job/cluster 다 삭제되니 신중.

### Workspace가 만들어졌는데 UI 접속 시 권한 에러

→ Azure AD에서 본인 계정이 워크스페이스 access 없음. Azure Portal → workspace → Access control (IAM) → "Contributor" 또는 Databricks 전용 role 부여.

---

## 다음 단계

- [02-metastore-assignment.md](02-metastore-assignment.md) (예정) — 기존 Unity Catalog metastore에 워크스페이스 할당
- [03-access-connector.md](03-access-connector.md) (예정) — ADLS 연동을 위한 Access Connector + Managed Identity
- [04-unity-catalog-objects.md](04-unity-catalog-objects.md) (예정) — Catalog, Schema, Grants를 IaC로
