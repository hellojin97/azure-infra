# 1단계: Azure 사전 준비 (Bootstrap)

GitHub Actions에서 Terraform으로 Azure를 조작하려면, **Terraform이 실행되기 전에 미리** 만들어 둬야 하는 것들이 있습니다. 이걸 "부트스트랩(bootstrap)"이라고 부르고, 한 번만 수동으로 진행합니다.

## 왜 한 번은 수동으로 해야 하는가 (닭과 달걀 문제)

Terraform은 state 파일을 어딘가 저장해야 하고, GitHub Actions는 Azure에 인증할 권한이 필요합니다. 그런데:

- state 저장소(Storage Account)는 Azure 안에 있어야 함
- 그 Storage Account에 접근할 권한도 미리 있어야 함

즉 "Terraform이 돌기 위한 환경"을 Terraform으로 만들 수는 없으므로, 이 부분은 Azure CLI로 직접 만듭니다.

## 핵심 개념

| 용어 | 설명 |
|---|---|
| **App Registration** | Azure AD에 "이런 앱이 존재해" 등록한 것. `Client ID` 발급받음 |
| **Service Principal (SP)** | App Registration의 실체. 실제로 권한을 행사하는 주체 |
| **Role Assignment** | SP에게 "이 스코프에서 이 역할을 해도 된다"고 부여 |
| **OIDC (OpenID Connect)** | GitHub Actions ↔ Azure를 시크릿 없이 연결하는 방식 |
| **Federated Credential** | "이 GitHub repo의 이 워크플로우에서 오는 토큰만 신뢰한다"는 규칙 |

OIDC 동작 흐름:

```text
[GitHub Actions 실행]
       │  ① GitHub이 OIDC 토큰 발급
       │     토큰 sub 클레임 예: repo:hellojin97/azure-infra:pull_request
       ▼
[Azure AD]
       │  ② sub가 등록된 federated credential과 일치하는지 검증
       │  ③ 일치하면 잠깐(몇 분) 쓸 수 있는 Access Token 발급
       ▼
[Terraform이 azurerm provider로 Azure 조작]
```

시크릿이 어디에도 저장되지 않는 이유: 매번 GitHub이 발급하는 새 토큰을 Azure가 검증해서 임시 통행증만 내주기 때문.

---

## 사전 조건

- Azure CLI(`az`)가 설치돼 있고 로그인 완료 (`az login`)
- GitHub CLI(`gh`)가 설치돼 있고 로그인 완료 (선택, 1-5 단계에서 사용)
- 작업할 GitHub repo가 이미 만들어져 있음

---

## 1-1. 변수 세팅

이후 단계에서 반복해서 쓸 값들을 셸 변수로 저장합니다. **같은 터미널 세션**에서 1-1부터 1-5까지 이어서 진행해야 변수가 살아있습니다.

```bash
# 현재 로그인된 구독 확인
az account show --output table

# 자주 쓸 값들을 셸 변수로 저장
export SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export TENANT_ID=$(az account show --query tenantId -o tsv)

# tfstate를 저장할 이름들
export TFSTATE_RG="rg-tfstate"
export TFSTATE_CONTAINER="tfstate"
export LOCATION="koreacentral"

# Storage Account 이름은 전 세계에서 유일해야 함 (3~24자, 소문자/숫자만)
export TFSTATE_SA="tfstatehj97$(openssl rand -hex 2)"

# GitHub repo (소유자/레포명)
export GH_REPO="hellojin97/azure-infra"

echo "Subscription : $SUBSCRIPTION_ID"
echo "Tenant       : $TENANT_ID"
echo "RG           : $TFSTATE_RG"
echo "Storage Acc  : $TFSTATE_SA"
echo "Container    : $TFSTATE_CONTAINER"
echo "Location     : $LOCATION"
echo "GitHub Repo  : $GH_REPO"
```

### 설명

- `TFSTATE_RG`: state 파일을 담을 Resource Group. **실제 인프라용 RG와 분리**해서 만들어야 실수로 같이 지워지지 않음.
- `TFSTATE_SA`: Storage Account 이름. Azure 전체에서 unique해야 해서 `openssl rand -hex 2`로 4글자 랜덤 suffix를 붙임.
- `TFSTATE_CONTAINER`: Storage Account 안의 Blob Container 이름. state 파일이 여기 들어감.

---

## 1-2. State 저장소 만들기

```bash
# Resource Group 생성
az group create \
  --name "$TFSTATE_RG" \
  --location "$LOCATION"

# Storage Account 생성
az storage account create \
  --name "$TFSTATE_SA" \
  --resource-group "$TFSTATE_RG" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --allow-blob-public-access false \
  --min-tls-version TLS1_2

# Container 생성 (Azure AD 인증으로)
az storage container create \
  --name "$TFSTATE_CONTAINER" \
  --account-name "$TFSTATE_SA" \
  --auth-mode login
```

### 옵션 설명

- `Standard_LRS`: 가장 저렴한 복제 옵션 (Locally-Redundant Storage). state 파일 정도면 충분.
- `--allow-blob-public-access false`: 외부 익명 접근 차단. state 파일에 인프라 정보가 다 있으니 필수.
- `--min-tls-version TLS1_2`: 옛날 TLS 거부. 보안 best practice.
- `--auth-mode login`: Container를 만들 때 access key가 아니라 본인의 az 로그인 계정을 사용. 이후 Terraform backend도 `use_azuread_auth = true`로 설정해서 access key를 안 쓸 예정.

### 확인

```bash
az storage account show \
  --name "$TFSTATE_SA" \
  --resource-group "$TFSTATE_RG" \
  --query "{name:name, location:location}" -o table

az storage container list \
  --account-name "$TFSTATE_SA" \
  --auth-mode login -o table
```

---

## 1-3. App Registration + Service Principal + 권한 부여

```bash
# App Registration 이름 (원하는 대로)
export APP_NAME="github-actions-azure-infra"

# 1) App Registration 생성하고 Client ID(=appId) 변수에 저장
export CLIENT_ID=$(az ad app create \
  --display-name "$APP_NAME" \
  --query appId -o tsv)
echo "Client ID: $CLIENT_ID"

# 2) Service Principal 생성
az ad sp create --id "$CLIENT_ID"

# 3) SP의 object-id 변수로 받기
export SP_OBJECT_ID=$(az ad sp show --id "$CLIENT_ID" --query id -o tsv)
echo "SP Object ID: $SP_OBJECT_ID"

# 4) Subscription 전체에 Contributor 권한 부여
az role assignment create \
  --role "Contributor" \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --scope "/subscriptions/$SUBSCRIPTION_ID"
```

### 설명

- **`appId` = Client ID**: 같은 값을 두 가지 이름으로 부릅니다.
- **Client ID vs Object ID**: 다른 값입니다.
  - Client ID(appId): App Registration의 globally unique ID
  - Object ID: SP가 테넌트 안에서 갖는 ID. role assignment에 사용
- **Contributor 역할**: 거의 모든 Azure 리소스를 만들고/수정/삭제 가능. 단 **IAM(role assignment, Key Vault 정책 등)은 못 함**.
- **시크릿을 안 만든다**: OIDC를 쓸 거라서 `az ad app credential create` 같은 시크릿 발급 명령은 하지 않음.

### 만약 나중에 Terraform으로 RBAC도 관리해야 한다면

`User Access Administrator` 역할을 추가로 부여하면 됨. 지금은 필요 없음.

```bash
# (필요할 때만)
az role assignment create \
  --role "User Access Administrator" \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --scope "/subscriptions/$SUBSCRIPTION_ID"
```

### 확인

```bash
az role assignment list --assignee "$CLIENT_ID" --all -o table
# Principal      Role         Scope
# -------------  -----------  -----------------------------
# <client-id>    Contributor  /subscriptions/<sub-id>
```

---

## 1-4. OIDC Federated Credentials 등록

App Registration에 "어느 GitHub repo의, 어느 컨텍스트에서 오는 토큰만 신뢰할지" 규칙을 붙입니다.

| 용도 | 트리거 | subject 값 |
|---|---|---|
| **plan** | PR 열림/업데이트 | `repo:OWNER/REPO:pull_request` |
| **apply** | main 브랜치 push | `repo:OWNER/REPO:ref:refs/heads/main` |

```bash
# GH_REPO가 제대로 set 되어있는지 먼저 확인 (안 되어있으면 1-1 다시)
echo "GH_REPO=$GH_REPO"

# 1) PR용 — plan 워크플로우 인증에 사용
az ad app federated-credential create \
  --id "$CLIENT_ID" \
  --parameters '{
    "name": "github-pull-request",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:'"$GH_REPO"':pull_request",
    "audiences": ["api://AzureADTokenExchange"]
  }'

# 2) main 브랜치용 — apply 워크플로우 인증에 사용
az ad app federated-credential create \
  --id "$CLIENT_ID" \
  --parameters '{
    "name": "github-main-branch",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:'"$GH_REPO"':ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

### 필드 설명

- **`issuer`**: GitHub의 OIDC 발급자 URL. 항상 `https://token.actions.githubusercontent.com` **고정**.
- **`subject`**: 토큰의 `sub` 클레임이 이 값과 **정확히 일치**해야 통과.
  - `pull_request`: 해당 repo에서 PR 이벤트로 실행된 워크플로우라면 모두 매칭 (브랜치 무관)
  - `ref:refs/heads/main`: main 브랜치에 push 됐을 때 실행된 워크플로우만 매칭
- **`audiences`**: Azure AD가 토큰 교환 시 검증할 audience. 항상 `["api://AzureADTokenExchange"]` **고정**.
- **`name`**: 본인이 알아보기 위한 식별 이름.

### JSON 안에서 셸 변수 쓰는 법

작은따옴표로 감싼 JSON 안에서는 셸 변수 치환이 안 됩니다. 변수 부분만 잠깐 큰따옴표로 빠져나왔다가 다시 작은따옴표로 이어 붙이는 패턴: `'foo:'"$VAR"':bar'`

### 잘못 등록한 경우 수정

subject가 비어있거나 잘못 들어갔으면 **삭제하지 말고 update**:

```bash
az ad app federated-credential update \
  --id "$CLIENT_ID" \
  --federated-credential-id "github-pull-request" \
  --parameters '{
    "name": "github-pull-request",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:'"$GH_REPO"':pull_request",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

`--federated-credential-id`에는 GUID 또는 이름을 넣을 수 있음. update도 전체 객체를 다시 보내야 함 (PATCH가 아니라 PUT).

### 보안 관점

- subject를 `repo:OWNER/REPO:*` 같은 와일드카드로 두면 어떤 브랜치/fork에서도 인증이 통과돼 위험. 좁게 정의하는 게 핵심.
- 더 안전하게 가려면 GitHub Environment(`environment:azure` 등)를 만들고 federated credential subject에 `environment:azure`를 추가, 그 환경에 "수동 승인자" 룰을 붙여서 apply가 사람 클릭 후에만 실행되게 할 수 있음.

### 확인

```bash
az ad app federated-credential list --id "$CLIENT_ID" -o table
# Name                 Subject
# -------------------  ----------------------------------------------------
# github-main-branch   repo:hellojin97/azure-infra:ref:refs/heads/main
# github-pull-request  repo:hellojin97/azure-infra:pull_request
```

---

## 1-5. GitHub Repo에 변수 등록

OIDC를 쓰면 `client_id`, `tenant_id`, `subscription_id`는 **민감 정보가 아닙니다** (시크릿이 없으니까). 그래서 Secrets가 아니라 **Variables**에 등록합니다.

### 등록할 값 6개

| GitHub Variable 이름 | 값 |
|---|---|
| `AZURE_CLIENT_ID` | `$CLIENT_ID` |
| `AZURE_TENANT_ID` | `$TENANT_ID` |
| `AZURE_SUBSCRIPTION_ID` | `$SUBSCRIPTION_ID` |
| `TFSTATE_RESOURCE_GROUP` | `$TFSTATE_RG` |
| `TFSTATE_STORAGE_ACCOUNT` | `$TFSTATE_SA` |
| `TFSTATE_CONTAINER` | `$TFSTATE_CONTAINER` |

### 방법 A: gh CLI로 (추천)

```bash
gh auth status   # 로그인 상태 확인 (안 되어있으면 gh auth login)

gh variable set AZURE_CLIENT_ID         --body "$CLIENT_ID"         --repo "$GH_REPO"
gh variable set AZURE_TENANT_ID         --body "$TENANT_ID"         --repo "$GH_REPO"
gh variable set AZURE_SUBSCRIPTION_ID   --body "$SUBSCRIPTION_ID"   --repo "$GH_REPO"
gh variable set TFSTATE_RESOURCE_GROUP  --body "$TFSTATE_RG"        --repo "$GH_REPO"
gh variable set TFSTATE_STORAGE_ACCOUNT --body "$TFSTATE_SA"        --repo "$GH_REPO"
gh variable set TFSTATE_CONTAINER       --body "$TFSTATE_CONTAINER" --repo "$GH_REPO"

gh variable list --repo "$GH_REPO"
```

### 방법 B: 웹 UI로

1. `https://github.com/<OWNER>/<REPO>/settings/variables/actions` 접속
2. **New repository variable** 클릭
3. 위 표의 6개 항목을 하나씩 등록

### Variables vs Secrets — 왜 Variables인가

- **Secrets**: 마스킹돼서 로그에 안 보임. 한 번 저장하면 다시 못 봄.
- **Variables**: 평문 저장. UI/CLI에서 값 확인 가능.
- 우리가 등록하는 6개 값은 **누가 알아도 보안 위협 없음**. OIDC federated credential이 "특정 GitHub repo의 특정 컨텍스트"에서만 토큰 교환을 허용하기 때문에, CLIENT_ID를 알아도 다른 데서는 못 씀.
- Variables로 두면 디버깅할 때 워크플로우 로그에서 값을 바로 확인할 수 있어서 편함.

### 워크플로우에서 참조 (다음 단계 미리보기)

```yaml
env:
  ARM_CLIENT_ID:       ${{ vars.AZURE_CLIENT_ID }}
  ARM_TENANT_ID:       ${{ vars.AZURE_TENANT_ID }}
  ARM_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}
  ARM_USE_OIDC:        true
```

`secrets.*`가 아니라 `vars.*`로 참조한다는 점 기억.

---

## 완료 체크리스트

- [ ] `az storage account list -g $TFSTATE_RG -o table` → Storage Account 존재
- [ ] `az role assignment list --assignee $CLIENT_ID --all -o table` → Contributor 한 줄
- [ ] `az ad app federated-credential list --id $CLIENT_ID -o table` → 두 줄, subject에 `OWNER/REPO`가 정확히 들어가있음
- [ ] `gh variable list --repo $GH_REPO` → 6개 변수

여기까지 완료되면 다음은 **2단계: Terraform 코드 작성**.

---

## 부록: 셸 변수 한 번에 다시 복원하기

새 터미널에서 1단계 변수들을 다시 복원하고 싶을 때:

```bash
export SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export TENANT_ID=$(az account show --query tenantId -o tsv)
export TFSTATE_RG="rg-tfstate"
export TFSTATE_CONTAINER="tfstate"
export LOCATION="koreacentral"
export GH_REPO="hellojin97/azure-infra"

# Storage Account 이름은 직접 알아내야 함 (랜덤 suffix가 있어서)
export TFSTATE_SA=$(az storage account list -g "$TFSTATE_RG" --query "[0].name" -o tsv)

# Client ID도 App Registration 이름으로 다시 조회
export APP_NAME="github-actions-azure-infra"
export CLIENT_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)

echo "TFSTATE_SA=$TFSTATE_SA"
echo "CLIENT_ID=$CLIENT_ID"
```
