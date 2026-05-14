# Azure Function: 별도 Repo에서 코드 배포 (uv 기반)

[01-app.md](01-app.md)에서 Terraform으로 Function App **인프라**를 만들었습니다. 이제 **함수 코드**를 별도 GitHub repo에서 관리하고 GitHub Actions로 배포하는 흐름을 잡습니다.

Python 패키징은 `uv` + `pyproject.toml` + `uv.lock` 조합으로 갑니다 (재현성 + 속도).

---

## 왜 repo를 분리하나

| 관심사 | Repo | 변경 빈도 | 변경 주체 |
|---|---|---|---|
| **인프라** (Function App, Storage, App Insights 등) | `azure-infra` | 낮음 (월 단위) | 플랫폼/DevOps |
| **함수 코드** (Python 로직, 의존성) | `azure-func-<name>` | 높음 (일/주 단위) | 개발자 |

장점:

- **변경 라이프사이클 분리** — 코드 100번 배포해도 인프라 plan은 안 돌아감
- **권한 분리** — 코드 배포 SP는 Function 배포 권한만 있으면 됨 (Contributor 같은 거 불필요)
- **CI 시간 단축** — 코드 zip만 만들고 deploy하면 끝, terraform 안 돌림

단점:

- repo가 늘어남 (작은 팀에서는 monorepo가 더 나을 수도)
- 인프라 변경과 코드 변경이 동시에 필요하면 조율 필요 (예: 새 환경변수 추가)

---

## 왜 uv + pyproject.toml + lock?

### uv

[Astral](https://astral.sh)에서 만든 Rust 기반 Python 도구. **pyenv + virtualenv + pip을 모두 대체**합니다.

- **속도**: pip의 10~100배 (resolution + install 둘 다)
- **Python 버전 관리**: `uv python install 3.11`
- **의존성 관리**: `uv add`, `uv sync`
- **재현성**: `uv.lock` 파일로 정확한 버전 잠금

### pyproject.toml

Python 표준 프로젝트 메타데이터 파일 (PEP 621). `requirements.txt`보다 풍부:

- 프로젝트 이름/버전/설명
- Python 버전 제약
- 의존성 (and dev/test/lint 그룹별)
- 도구 설정 (ruff, mypy 등)

### uv.lock

`requirements.txt`가 "원하는 의존성"이라면, `uv.lock`은 **"실제로 설치된 정확한 버전 + 해시"**. npm의 `package-lock.json`과 같은 역할:

- 모든 transitive 의존성까지 정확한 버전 기록
- 해시로 변조 방지
- CI/팀원 모두 100% 같은 환경

→ **`uv.lock`은 반드시 git commit**.

---

## 새 Repo 구조

```text
azure-func-hello/
├── function_app.py        # 함수 코드 (entry point)
├── host.json              # Functions runtime 설정
├── pyproject.toml         # 프로젝트 메타데이터 + 의존성 선언
├── uv.lock                # 실제 설치된 버전 잠금 (commit!)
├── .python-version        # Python 버전 고정 (commit)
├── local.settings.json    # 로컬 실행용 설정 (gitignore!)
├── .funcignore            # zip 패키징에서 제외할 파일
├── .gitignore
└── .github/
    └── workflows/
        └── deploy.yml     # build + deploy
```

### 새 GitHub repo 생성

```bash
gh repo create azure-func-hello --public --clone
cd azure-func-hello
```

---

## 사전 도구

### uv 설치

```bash
# Mac (Homebrew)
brew install uv

# 또는 공식 installer
curl -LsSf https://astral.sh/uv/install.sh | sh

uv --version
```

### Azure Functions Core Tools

로컬에서 함수 실행/디버깅 용. 배포만 하면 없어도 OK.

```bash
brew tap azure/functions
brew install azure-functions-core-tools@4

func --version  # 4.x.x
```

---

## 프로젝트 초기화 (uv)

### 1) Python 3.11 설치 + 프로젝트 고정

```bash
cd azure-func-hello

uv python install 3.11      # 시스템에 Python 3.11 설치 (이미 있으면 skip)
uv python pin 3.11           # 이 프로젝트는 3.11 사용 → .python-version 생성
```

### 2) `pyproject.toml` + `uv.lock` 생성

```bash
uv init --no-readme --no-package
# pyproject.toml 생성됨
```

생성된 `pyproject.toml`을 다음과 같이 정리:

```toml
[project]
name = "azure-func-hello"
version = "0.1.0"
description = "Azure Functions hello world"
requires-python = ">=3.11,<3.12"
dependencies = []

[tool.uv]
package = false
```

### 3) 의존성 추가

```bash
uv add azure-functions
```

이 명령이 실행되면:

- `pyproject.toml`의 `dependencies`에 `azure-functions>=...` 추가
- `uv.lock` 생성/업데이트 (정확한 버전 + 해시 기록)
- `.venv/` 자동 생성 + 설치

### 4) `uv init` 시 자동 생성된 잡파일 정리

`uv init`이 만들어준 파일 중 함수 앱에 불필요한 것들 삭제:

```bash
rm -f main.py hello.py README.md   # 있다면
```

---

## 함수 코드 — HTTP Trigger Hello World (Python v2 model)

### `function_app.py`

```python
import azure.functions as func
import logging

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)


@app.route(route="hello")
def hello(req: func.HttpRequest) -> func.HttpResponse:
    logging.info("Python HTTP trigger function processed a request.")

    name = req.params.get("name") or "world"
    return func.HttpResponse(
        f"Hello, {name}!",
        status_code=200,
    )
```

### 줄별 설명

- **`func.FunctionApp(http_auth_level=...)`**: Python v2 programming model의 entry. 파일 하나에 여러 함수 데코레이터로 등록.
- **`http_auth_level=AuthLevel.FUNCTION`**: HTTP trigger 호출 시 function key 필요. 다른 옵션:
  - `ANONYMOUS` — 인증 없이 호출 가능 (공개 API용)
  - `ADMIN` — admin key (master key) 필요
- **`@app.route(route="hello")`**: `/api/hello` 경로로 매핑.
- **`logging.info(...)`**: App Insights에 자동 수집됨.

### `host.json`

```json
{
    "version": "2.0",
    "logging": {
        "applicationInsights": {
            "samplingSettings": {
                "isEnabled": true,
                "excludedTypes": "Request"
            }
        }
    },
    "extensionBundle": {
        "id": "Microsoft.Azure.Functions.ExtensionBundle",
        "version": "[4.*, 5.0.0)"
    }
}
```

- **`extensionBundle`**: trigger/binding extension(Blob, Queue, EventGrid 등)을 자동 관리. v4 bundle = Functions runtime v4.

### `local.settings.json`

```json
{
    "IsEncrypted": false,
    "Values": {
        "AzureWebJobsStorage": "UseDevelopmentStorage=true",
        "FUNCTIONS_WORKER_RUNTIME": "python",
        "AzureWebJobsFeatureFlags": "EnableWorkerIndexing"
    }
}
```

- **로컬 실행 시에만 사용**. 배포 안 됨.
- **반드시 .gitignore에 추가** — 환경별 secret 들어갈 수 있음.
- **`EnableWorkerIndexing`**: Python v2 model 활성화. 필수.

### `.funcignore`

zip 패키징 시 제외할 파일들:

```text
.git*
.vscode
.venv
.python-version
local.settings.json
test
__pycache__
.pytest_cache
.ruff_cache
.mypy_cache
pyproject.toml
uv.lock
```

⚠️ **주의**: `pyproject.toml`과 `uv.lock`은 배포 zip에서 제외합니다 — Functions 런타임은 이 파일을 읽지 않고, `.python_packages/`에 미리 설치된 라이브러리만 사용. zip 사이즈 줄이는 효과.

### `.gitignore`

```gitignore
# Python
__pycache__/
*.py[cod]
.venv/

# Functions
local.settings.json
bin/
obj/
.python_packages/

# uv
# uv.lock 은 commit (재현성)
# .python-version 은 commit (팀원 동일 버전)

# OS
.DS_Store
.vscode/
```

`.python_packages/`는 CI에서만 만드니 gitignore.

### `pyproject.toml` (최종)

```toml
[project]
name = "azure-func-hello"
version = "0.1.0"
description = "Azure Functions hello world"
requires-python = ">=3.11,<3.12"
dependencies = [
    "azure-functions>=1.18.0",
]

[tool.uv]
package = false
```

---

## 로컬 실행

```bash
# uv.lock 기준으로 정확히 동기화 (.venv 생성/업데이트)
uv sync

# Functions 호스트 실행
uv run func start

# 다른 터미널에서 호출
curl "http://localhost:7071/api/hello?name=Hyunjin"
# Hello, Hyunjin!
```

`uv run`을 쓰면 `.venv` 활성화 없이 한 번에 실행됨. 아니면:

```bash
source .venv/bin/activate
func start
```

---

## OIDC 인증 — 새 SP 생성 (권장)

`azure-infra` repo의 SP는 Contributor 권한이 있어 너무 광범위함. **함수 배포만 가능한 별도 SP**를 만들어 최소 권한 원칙 적용.

### 1) App Registration + SP 생성

```bash
export APP_NAME="github-actions-azure-func-hello"

export FUNC_CLIENT_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
echo "Func Client ID: $FUNC_CLIENT_ID"

az ad sp create --id "$FUNC_CLIENT_ID"

export FUNC_SP_OBJECT_ID=$(az ad sp show --id "$FUNC_CLIENT_ID" --query id -o tsv)
echo "Func SP Object ID: $FUNC_SP_OBJECT_ID"
```

### 2) 권한 부여 — Function App scope만

```bash
export SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export FUNC_NAME="func-app-lab-kc"
export FUNC_RG="rg-app-lab-kc"

export FUNC_SCOPE=$(az functionapp show -n "$FUNC_NAME" -g "$FUNC_RG" --query id -o tsv)

# Website Contributor — 코드 배포에 필요한 최소 권한
az role assignment create \
  --role "Website Contributor" \
  --assignee-object-id "$FUNC_SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --scope "$FUNC_SCOPE"
```

`Website Contributor`는 **App Service 리소스에 한정된 배포 권한**. Subscription Contributor보다 훨씬 좁음.

### 3) Federated Credential — 새 repo 컨텍스트로

```bash
export GH_REPO="hellojin97/azure-func-hello"

# main 브랜치 push용
az ad app federated-credential create \
  --id "$FUNC_CLIENT_ID" \
  --parameters '{
    "name": "github-main-branch",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:'"$GH_REPO"':ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'

# (선택) PR용 — PR에서 build/test만 돌릴 때
az ad app federated-credential create \
  --id "$FUNC_CLIENT_ID" \
  --parameters '{
    "name": "github-pull-request",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:'"$GH_REPO"':pull_request",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

### 4) GitHub repo Variables 등록

```bash
gh variable set AZURE_CLIENT_ID         --body "$FUNC_CLIENT_ID"   --repo "$GH_REPO"
gh variable set AZURE_TENANT_ID         --body "$(az account show --query tenantId -o tsv)" --repo "$GH_REPO"
gh variable set AZURE_SUBSCRIPTION_ID   --body "$SUBSCRIPTION_ID"  --repo "$GH_REPO"
gh variable set AZURE_FUNCTIONAPP_NAME  --body "$FUNC_NAME"        --repo "$GH_REPO"
```

---

## GitHub Actions Deploy Workflow

`.github/workflows/deploy.yml`:

```yaml
name: Deploy Function

on:
    push:
        branches: [main]
        paths-ignore:
            - "**.md"
            - ".gitignore"
    workflow_dispatch:

permissions:
    id-token: write
    contents: read

concurrency:
    group: deploy-function
    cancel-in-progress: false

jobs:
    deploy:
        name: build & deploy
        runs-on: ubuntu-latest

        steps:
            - name: Checkout
              uses: actions/checkout@v4

            - name: Install uv
              uses: astral-sh/setup-uv@v3
              with:
                  enable-cache: true

            - name: Install Python (from .python-version)
              run: uv python install

            - name: Install dependencies into .python_packages
              run: |
                  # uv.lock 기준으로 deploy용 requirements 생성 후 target 설치
                  uv export \
                    --no-hashes \
                    --no-emit-project \
                    --frozen \
                    --output-file requirements-deploy.txt
                  uv pip install \
                    --python 3.11 \
                    --target=".python_packages/lib/site-packages" \
                    -r requirements-deploy.txt

            - name: Azure Login (OIDC)
              uses: azure/login@v2
              with:
                  client-id:       ${{ vars.AZURE_CLIENT_ID }}
                  tenant-id:       ${{ vars.AZURE_TENANT_ID }}
                  subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

            - name: Deploy to Function App
              uses: Azure/functions-action@v1
              with:
                  app-name: ${{ vars.AZURE_FUNCTIONAPP_NAME }}
                  package: "."
                  scm-do-build-during-deployment: false
                  enable-oryx-build: false
```

### 줄별 짚기

#### `astral-sh/setup-uv@v3`

- uv 자동 설치 + 캐싱.
- `enable-cache: true` — `uv.lock` 기반으로 의존성 캐싱. 빌드 시간 추가 단축.

#### `uv python install`

- `.python-version` 파일을 읽어서 정확한 Python 버전 자동 설치.

#### `uv export ... --frozen`

- `uv.lock`의 정확한 버전을 `requirements-deploy.txt`로 export.
- **`--frozen`**: lock 파일을 절대 갱신 안 하고 그대로 사용 → 재현성 보장.
- **`--no-hashes`**: pip은 해시를 다른 방식으로 검증해서, target 설치 시 hash가 오히려 문제 일으킬 수 있어 제외.
- **`--no-emit-project`**: 자기 자신(`azure-func-hello`)은 제외, 의존성만.

#### `uv pip install --target=.python_packages/lib/site-packages`

- Python Functions 배포의 핵심.
- 모든 의존성을 **`.python_packages/`** 디렉토리에 미리 설치 → zip에 포함시킴.
- 그러면 배포 후 추가 빌드 없이 바로 import 가능.

#### `Azure/functions-action@v1`

- 공식 액션. 위에서 만든 zip을 Function App에 배포.
- `scm-do-build-during-deployment: false` — server에서 또 빌드 안 함
- `enable-oryx-build: false` — Oryx (App Service 자동 빌드) 비활성

---

## 첫 배포

```bash
git add .
git commit -m "Initial Function App with hello HTTP trigger"
git push -u origin main

gh run watch
```

성공 후 호출:

```bash
FUNC_URL=$(az functionapp function show \
  --name "func-app-lab-kc" \
  --resource-group "rg-app-lab-kc" \
  --function-name "hello" \
  --query "invokeUrlTemplate" -o tsv)

FUNC_KEY=$(az functionapp keys list \
  -n "func-app-lab-kc" \
  -g "rg-app-lab-kc" \
  --query "functionKeys.default" -o tsv)

curl "${FUNC_URL}?code=${FUNC_KEY}&name=Hyunjin"
# Hello, Hyunjin!
```

> 첫 배포 후 함수가 인덱싱되기까지 1-2분 걸릴 수 있음. 404 뜨면 잠시 후 retry.

---

## 일상 개발 흐름

```bash
# 새 의존성 추가
uv add requests
# → pyproject.toml + uv.lock 동시 갱신

# 의존성 제거
uv remove requests

# 의존성 업그레이드
uv lock --upgrade-package azure-functions

# 동기화 (uv.lock과 .venv 일치시키기)
uv sync

# Python 버전 변경
uv python pin 3.12
# 다음 uv sync 시 .venv를 3.12로 재생성
```

→ `pyproject.toml`과 `uv.lock` 변경분을 PR로 올리면 CI가 자동 검증/배포.

---

## 자주 만나는 에러

### `Function not found` (배포는 성공했는데 호출 시 404)

**원인 가능성**:

1. 인덱싱 대기 중 — 1-2분 후 retry
2. `EnableWorkerIndexing` flag가 Function App에 안 켜져있음 — Python v2 model 필수

해결:

```bash
az functionapp config appsettings set \
  -n "func-app-lab-kc" -g "rg-app-lab-kc" \
  --settings AzureWebJobsFeatureFlags=EnableWorkerIndexing
```

또는 Terraform 인프라 모듈에 추가:

```hcl
# modules/function/main.tf 의 azurerm_linux_function_app 블록
app_settings = {
  AzureWebJobsFeatureFlags = "EnableWorkerIndexing"
}
```

### `ModuleNotFoundError: No module named 'azure.functions'`

**원인**: 의존성이 zip에 포함 안 됨.

해결:

1. CI 로그 확인 — `uv export` + `uv pip install --target=...` step이 성공했는지
2. `.python_packages/lib/site-packages/` 디렉토리에 라이브러리가 들어갔는지 (CI에서 `ls` 추가해서 확인)
3. `.funcignore`에 `.python_packages` 가 들어가있지 않은지 (제외하면 안 됨!)

### `error: failed to read pyproject.toml`

**원인**: `pyproject.toml`이 망가졌거나 없음.

해결: 위 [pyproject.toml 최종](#pyprojecttoml-최종) 형태와 비교해서 수정.

### `403 You do not have permission to perform this action`

**원인**: SP에 `Website Contributor` 안 부여됨, 또는 federated credential subject 매칭 실패.

해결:

```bash
# 권한 확인
az role assignment list --assignee "$FUNC_CLIENT_ID" --scope "$FUNC_SCOPE" -o table

# federated credential 확인
az ad app federated-credential list --id "$FUNC_CLIENT_ID" -o table
# subject가 'repo:OWNER/azure-func-hello:ref:refs/heads/main' 이어야 함
```

### `uv.lock is out of date`

**원인**: 누가 `pyproject.toml`만 수정하고 `uv.lock`을 안 갱신함.

해결: 로컬에서 `uv lock` → 변경된 `uv.lock` commit.

CI에서 검증하려면 deploy.yml에 한 step 추가:

```yaml
- name: Verify lock file
  run: uv lock --check
```

---

## 인프라 변경이 필요한 경우 (조율 패턴)

함수 코드가 새 환경변수나 새 trigger를 쓰려면 인프라도 같이 바뀌어야 합니다. 이때:

1. **인프라 먼저 변경** — `azure-infra` repo에서 PR → 머지 → apply
2. **그 다음 코드 배포** — `azure-func-hello` repo에서 PR → 머지 → deploy

순서가 중요. 코드 먼저 배포하면 새 env var를 못 찾아서 런타임 에러.

예: 새 환경변수 추가

```hcl
# azure-infra: modules/function/main.tf
app_settings = {
  AzureWebJobsFeatureFlags = "EnableWorkerIndexing"
  ADLS_ACCOUNT_URL         = "https://stadlsapplabkc.dfs.core.windows.net"  # NEW
  KEYVAULT_URL             = "https://kv-app-lab-kc.vault.azure.net/"        # NEW
}
```

→ 인프라 apply 끝난 후, app repo에서 `os.environ["ADLS_ACCOUNT_URL"]` 사용.

---

## 다음 단계

- [03-managed-identity-rbac.md](03-managed-identity-rbac.md) (예정) — Function MI를 ADLS/Key Vault에 RBAC 부여
- [04-private-endpoint.md](04-private-endpoint.md) (예정) — Premium 으로 옮기고 VNet integration + private endpoint
- (선택) Slot deployment — staging slot에 배포 → swap 패턴
- (선택) End-to-end test — deploy 후 smoke test 자동화
- (선택) `ruff` + `mypy` lint/type check를 PR 워크플로우에 추가 (uv가 이미 깔려있으니 `uv run ruff check` 한 줄)
