# 2단계: Terraform 코드 작성

[1단계](01-azure-bootstrap.md)에서 Azure 사전 준비를 끝냈으면, 이제 Terraform 코드를 작성합니다. 이 단계의 목표는:

1. 최소한의 Terraform 코드 작성 (인증/state backend가 동작하는지 확인할 수 있는 정도)
2. **로컬에서** 한 번 init/plan/apply 돌려 동작 검증 (CI로 가기 전에 디버깅 환경 확보)
3. 실제 인프라 리소스는 다음에 추가

---

## 2-0. 큰 그림

만들 파일 구조:

```
azure-infra/
├── .gitignore
├── docs/
│   ├── 01-azure-bootstrap.md
│   └── 02-terraform-skeleton.md
└── terraform/
    ├── versions.tf      # Terraform / Provider 버전 잠금
    ├── providers.tf     # azurerm provider 설정
    ├── backend.tf       # state를 Azure Storage에 저장하는 설정
    ├── main.tf          # 실제 리소스 (지금은 인증 검증용 data source만)
    └── outputs.tf       # 출력값
```

### 왜 파일을 이렇게 쪼개나

Terraform은 한 디렉토리 안의 **모든 `.tf` 파일을 알파벳 순으로 합쳐서** 하나로 처리합니다. 즉 `main.tf` 하나에 다 써도 동작은 똑같음. 그런데 관습적으로:

| 파일 | 역할 |
|---|---|
| `versions.tf` | Terraform 자체와 provider의 **버전 제약** |
| `providers.tf` | Provider **인스턴스 설정** |
| `backend.tf` | **State 백엔드** 설정 |
| `main.tf` | 실제 **리소스** 정의 |
| `variables.tf` | 입력 **변수** 선언 |
| `outputs.tf` | **출력값** 선언 |

이렇게 나누면 "이 설정이 어디 있더라" 찾기 쉽고, PR 리뷰할 때 변경의 의도가 한눈에 보입니다.

---

## 2-1. `.gitignore`

Terraform이 만드는 파일 중 **절대 commit하면 안 되는 것**들이 있어 미리 막아둡니다.

### 핵심 패턴

```gitignore
# Terraform
**/.terraform/*
*.tfstate
*.tfstate.*
*.tfvars
*.tfvars.json
crash.log
crash.*.log
override.tf
override.tf.json
*_override.tf
*_override.tf.json

# OS / editor
.DS_Store
.vscode/*
!.vscode/settings.json
```

(VSCode의 ".gitignore Generator" 같은 도구로 생성한 더 광범위한 .gitignore를 써도 OK — 위 항목들이 포함되어 있는지만 확인.)

### 왜 각각 막는지

- **`**/.terraform/*`**: `terraform init` 시 provider 바이너리(수십 MB)와 modules 캐시가 들어감. 머신마다 다시 받으면 됨, commit하면 레포 비대.
- **`*.tfstate`, `*.tfstate.*`**: state 파일. 우리는 Azure Storage에 두기로 했으니 로컬에 생기면 안 되지만, 안전망으로 ignore.
- **`*.tfvars`**: 실제 값을 담는 변수 파일. 시크릿/환경별 값이 들어감. 실수로 commit하면 누출 위험.
- **`crash.log`**: Terraform이 죽었을 때 남는 디버그 로그.
- **`override.tf`** 계열: 로컬에서 임시로 동작 바꿀 때 쓰는 메커니즘. 공유하면 안 됨.

### 절대 ignore하면 안 되는 것

- **`.terraform.lock.hcl`** — provider 정확한 버전 + 체크섬을 잠그는 lock 파일. **반드시 commit**해야 팀원/CI가 같은 provider를 씁니다.

---

## 2-2. `terraform/versions.tf`

```hcl
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}
```

### 줄별 설명

- **`required_version = ">= 1.9.0"`**: Terraform CLI 1.9.0 이상 강제. 팀원/CI가 옛날 버전 쓰는 걸 막아줌.
- **`required_providers`**: 어떤 provider를 어디서 받을지.
  - `source = "hashicorp/azurerm"`: HashiCorp 공식 Azure provider.
  - `version = "~> 4.0"`: **pessimistic constraint**.

### `~>` 연산자 의미

- `~> 4.0` → `>= 4.0, < 5.0`
- `~> 4.20` → `>= 4.20, < 4.21` (마지막 자리 고정)
- 보통 major만 잠그고 minor/patch는 허용하는 `~> 4.0` 패턴을 씁니다.

---

## 2-3. `terraform/providers.tf`

azurerm provider 인스턴스 설정. 두 가지 스타일이 있는데 우리는 **환경변수 의존 버전**을 사용합니다.

```hcl
provider "azurerm" {
  features {}
  use_oidc = true
}
```

### 줄별 설명

- **`features {}`**: azurerm이 **필수**로 요구하는 빈 블록. 안에 옵션 넣어 동작 변경 가능 (예: `resource_group { prevent_deletion_if_contains_resources = false }`). 일단 비워둠.
- **`use_oidc = true`**: OIDC 모드 켜기. GitHub Actions에서 발급받은 토큰을 자동으로 사용해 인증.

### 인증 정보는 어디서?

azurerm provider는 `ARM_CLIENT_ID`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`, `ARM_USE_OIDC` 같은 **환경변수를 자동으로 읽습니다**. 그래서 코드에 client_id 같은 걸 박아두지 않아도 됨.

### 두 가지 스타일 비교

| 스타일 | 장점 | 단점 |
|---|---|---|
| **환경변수 의존** (이 가이드) | 코드 깨끗, 환경별 재사용 쉬움 | 어떤 환경변수가 필요한지는 따로 문서화 필요 |
| **변수로 명시적 선언** | 코드만 보고 무엇이 필요한지 명확 | variables.tf, tfvars 같이 관리 필요 |

---

## 2-4. `terraform/backend.tf`

State를 Azure Storage에 저장하는 설정.

```hcl
terraform {
  backend "azurerm" {
    use_oidc         = true
    use_azuread_auth = true
  }
}
```

### 줄별 설명

- **`backend "azurerm"`**: state 백엔드로 azurerm을 쓰겠다는 선언.
- **`use_oidc = true`**: backend도 OIDC로 인증.
- **`use_azuread_auth = true`**: Storage Account 접근 시 **access key가 아니라 Azure AD 토큰**으로 인증. 1단계에서 container 만들 때 `--auth-mode login`을 쓴 이유. access key를 안 다뤄서 더 안전.

### "어떤 storage account인지"는 왜 안 적나? — partial backend configuration

`storage_account_name`, `container_name`, `key`, `resource_group_name` 같은 값을 **여기 코드에 안 적고**, `terraform init` 명령에 인자로 따로 넘깁니다:

```bash
terraform init \
  -backend-config="resource_group_name=$TFSTATE_RG" \
  -backend-config="storage_account_name=$TFSTATE_SA" \
  -backend-config="container_name=$TFSTATE_CONTAINER" \
  -backend-config="key=terraform.tfstate"
```

**왜 이렇게 분리하나?**
- Storage Account 이름은 환경마다 다를 수 있음 (랜덤 suffix 포함)
- 환경별로 다른 backend를 쓰고 싶을 때 같은 코드 재사용 가능
- 코드에 인프라 식별자가 박혀있지 않으니 fork/공개 시 안전

이 init 명령은 로컬에서는 본인이 직접, CI에서는 GitHub Actions가 실행합니다.

> **이 파일을 작성한 시점에는 `terraform init`을 실행하지 마세요.** 2-7 단계에서 같이 다룹니다.

---

## 2-5. `terraform/main.tf`

빈 시작 템플릿이지만, **OIDC 인증이 진짜 통하는지 확인할 한 줄**은 넣어두면 좋습니다. 실제 리소스를 만들지 않고 "현재 구독 정보를 읽어오기"만 하는 data source.

```hcl
data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}
```

### 설명

- **`data` 블록**: Terraform이 **읽기만** 하고 만들지 않는 자원. resource는 create/update/destroy를 하고, data는 fetch만.
- **`azurerm_client_config`**: 현재 인증된 주체의 정보 (client_id, tenant_id, object_id).
- **`azurerm_subscription`**: 현재 구독의 정보 (id, name, location).

이 둘이 있으면 `terraform plan`이 "Azure에 인증해서 데이터 읽어오기"까지 시도하므로 OIDC가 동작하는지 확인됩니다. **리소스는 안 만들어요** — 안전.

---

## 2-6. `terraform/outputs.tf`

방금 읽은 값들을 출력으로 뽑아 plan/apply 결과에 표시:

```hcl
output "subscription_id" {
  description = "Currently authenticated Azure subscription ID"
  value       = data.azurerm_subscription.current.subscription_id
}

output "subscription_name" {
  description = "Currently authenticated Azure subscription name"
  value       = data.azurerm_subscription.current.display_name
}

output "client_object_id" {
  description = "Object ID of the principal Terraform is running as"
  value       = data.azurerm_client_config.current.object_id
}
```

### 설명

- **`output`**: 외부에서 참조 가능한 출력값. apply 끝나면 콘솔에 찍히고, 다른 Terraform 코드에서도 읽어갈 수 있음.
- 이 셋이 보이면 "SP가 정상적으로 Azure에 붙어 데이터를 읽어왔다"는 증거.

---

## 2-7. 로컬에서 동작 확인

순서: ① 사전 권한 부여 → ② init → ③ fmt/validate → ④ plan → ⑤ (선택) apply

### ① 사전: Storage Blob Data Contributor 권한 부여

이게 1단계에서 빠뜨리기 쉬운 부분이에요. Azure RBAC에는 두 plane이 있습니다:

| Plane | 의미 | Contributor가 되나? |
|---|---|---|
| **Management plane** | Storage Account를 만들고/삭제/설정 | ✅ 됨 |
| **Data plane** | Storage Account **안의 blob을 읽고/쓰고** | ❌ 안 됨 |

`use_azuread_auth = true` backend는 blob을 list/read/write — **이건 data plane**. Contributor만으로는 부족하고 별도 역할이 필요합니다: **`Storage Blob Data Contributor`**.

또 하나, 지금은 **본인 az 로그인 계정**으로 init을 돌릴 거라서 본인 계정에도 권한이 필요합니다 (SP가 아님). GitHub Actions에서는 SP가 돌리니까 SP에도 같이 부여:

```bash
# 셸 변수 살아있는지 확인 (없으면 1단계 부록의 복원 명령 실행)
echo "TFSTATE_RG=$TFSTATE_RG / TFSTATE_SA=$TFSTATE_SA / CLIENT_ID=$CLIENT_ID"

# 필요시 다시 받기
export SP_OBJECT_ID=$(az ad sp show --id "$CLIENT_ID" --query id -o tsv)
export MY_USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
export SA_SCOPE=$(az storage account show -n "$TFSTATE_SA" -g "$TFSTATE_RG" --query id -o tsv)

# 1) 본인 user 계정 (로컬 테스트용)
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee-object-id "$MY_USER_OBJECT_ID" \
  --assignee-principal-type User \
  --scope "$SA_SCOPE"

# 2) Service Principal (GitHub Actions용)
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --scope "$SA_SCOPE"
```

#### 권한 전파 대기

Azure RBAC는 부여 후 **수 초 ~ 5분** 정도 전파 시간이 걸립니다. 다음 단계에서 403이 나면 1~2분 기다렸다가 retry하세요.

#### 권한 들어갔는지 확인

```bash
# Storage Account scope의 role 전부 (상속 포함)
az role assignment list --scope "$SA_SCOPE" --include-inherited -o table

# 본인 user 기준만
az role assignment list \
  --assignee "$MY_USER_OBJECT_ID" \
  --scope "$SA_SCOPE" \
  --include-inherited -o table
```

> ⚠️ `--all`과 `--scope`는 동시에 못 씁니다. `--include-inherited`로 상속까지 포함해 보세요.

전파 효력을 빨리 체크하려면 az CLI로 직접:

```bash
az storage blob list \
  --account-name "$TFSTATE_SA" \
  --container-name "$TFSTATE_CONTAINER" \
  --auth-mode login -o table
```

빈 출력만 떠도 권한 OK. 403이면 아직 전파 중.

### ② `terraform init`

```bash
cd /Users/dawn/azure-infra/terraform

terraform init \
  -backend-config="resource_group_name=$TFSTATE_RG" \
  -backend-config="storage_account_name=$TFSTATE_SA" \
  -backend-config="container_name=$TFSTATE_CONTAINER" \
  -backend-config="key=terraform.tfstate"
```

기대 결과:
```
Initializing the backend...
Successfully configured the backend "azurerm"!
...
Initializing provider plugins...
- Installing hashicorp/azurerm v4.x.x...
...
Terraform has been successfully initialized!
```

이때 만들어지는 것:
- `.terraform/` 디렉토리 (provider 바이너리) — gitignore됨
- `.terraform.lock.hcl` (provider 버전 잠금) — **commit해야 함**

### ③ `terraform fmt` + `terraform validate`

```bash
# 코드 자동 포맷
terraform fmt -recursive

# 설정 검증 (init 다음에)
terraform validate
```

기대 결과:
```
Success! The configuration is valid.
```

### ④ `terraform plan`

```bash
terraform plan
```

기대 결과:
```
Acquiring state lock. This may take a few moments...
data.azurerm_client_config.current: Reading...
data.azurerm_subscription.current: Reading...
data.azurerm_client_config.current: Read complete after 1s [...]
data.azurerm_subscription.current: Read complete after 1s [...]

Changes to Outputs:
  + client_object_id  = "..."
  + subscription_id   = "..."
  + subscription_name = "..."

Releasing state lock. This may take a few moments...
```

이 출력의 의미:

| 라인 | 무엇을 증명하나 |
|---|---|
| `Acquiring state lock` | State backend의 **블롭 lease 잠금**이 작동 — 동시성 안전 |
| `Reading...` → `Read complete` | Azure AD 인증 OK + provider가 구독에 접근 OK |
| `Changes to Outputs: + ...` | data source 값이 정확히 계산됨 |
| `Releasing state lock` | lease 정상 해제 — backend 라이프사이클 정상 |

핵심: **`Plan: 0 to add, 0 to change, 0 to destroy`** — 만들 리소스 없음 (의도대로).

### ⑤ (선택) `terraform apply`

state 파일이 진짜 blob에 쓰이는지까지 확인하려면:

```bash
terraform apply
# yes 입력

# state 파일 확인
az storage blob list \
  --account-name "$TFSTATE_SA" \
  --container-name "$TFSTATE_CONTAINER" \
  --auth-mode login -o table
# terraform.tfstate 가 보여야 함

# 저장된 outputs 확인
terraform output
```

리소스가 없어도 outputs는 state에 기록되고, container에 첫 state 파일이 만들어집니다.

---

## 자주 만나는 에러

### 에러: `403 AuthorizationPermissionMismatch` (terraform init 시)

```
Error: Failed to get existing workspaces: listing blobs:
executing request: unexpected status 403 (...) with AuthorizationPermissionMismatch
```

**원인**: `Storage Blob Data Contributor` 역할이 본인 user(또는 SP)에 없음. Subscription scope의 Contributor만으로는 부족.

**해결**: 위 ①번 단계의 grant 명령 실행 → 1~5분 전파 대기 → retry.

### 에러: `Backend reinitialization required`

backend 설정이 바뀌었을 때 발생. `-reconfigure` 옵션을 붙여 다시 init:

```bash
terraform init -reconfigure \
  -backend-config="..." ...
```

### 에러: `The current implementation of Terraform uses the following provider`

provider 버전이 lock 파일과 불일치. 보통 다른 머신에서 만든 lock 파일과 OS/arch가 다른 경우. `.terraform.lock.hcl`에 OS별 hash를 추가:

```bash
terraform providers lock -platform=linux_amd64 -platform=darwin_arm64
```

---

## 완료 체크리스트

- [ ] `.gitignore`에 `*.tfstate`, `**/.terraform/*`, `*.tfvars` 포함
- [ ] `terraform/versions.tf`, `providers.tf`, `backend.tf`, `main.tf`, `outputs.tf` 작성 완료
- [ ] 본인 계정 + SP 둘 다 `Storage Blob Data Contributor` 부여 완료
- [ ] `terraform init` 성공
- [ ] `terraform validate` 통과
- [ ] `terraform plan` 통과 (data source Read 성공, outputs 표시)
- [ ] (선택) `terraform apply` 성공 + container에 `terraform.tfstate` 생성 확인
- [ ] `terraform/.terraform.lock.hcl` 포함해서 git commit & push 완료

---

## 다음 단계

이제 같은 일을 GitHub Actions가 OIDC + SP로 자동 수행하게 만듭니다 → **3단계: GitHub Actions 워크플로우 작성**.
