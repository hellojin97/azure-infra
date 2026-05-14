# 3단계: GitHub Actions 워크플로우 작성

[1단계](01-azure-bootstrap.md)와 [2단계](02-terraform-skeleton.md)에서 했던 것을 GitHub Actions가 OIDC + Service Principal로 자동 수행하게 만듭니다.

---

## 3-0. 큰 그림

만들 워크플로우 두 개:

```text
.github/workflows/
├── terraform-plan.yml   ─── PR 열림/업데이트 시 → terraform plan
└── terraform-apply.yml  ─── main 브랜치에 push 시 → terraform plan + apply
```

### 동작 흐름

```text
[개발자] feature 브랜치에서 코드 수정 → push → PR 오픈
                                        │
                                        ▼
                          terraform-plan.yml 실행
                          - OIDC로 Azure 인증
                          - terraform plan (read-only 미리보기)
                          - 결과를 PR Checks/Summary에 출력
                                        │
                  [리뷰 OK 후] main에 머지 ──────┐
                                                 ▼
                                terraform-apply.yml 실행
                                - OIDC로 Azure 인증
                                - terraform plan + apply (saved plan)
                                - 변경 사항 실제 반영
```

### 두 워크플로우의 공통 요소

| 요소 | 용도 |
|---|---|
| `permissions: id-token: write` | **OIDC 토큰 발급 받기 위한 필수 권한** |
| `azure/login@v2` (OIDC 모드) | GitHub OIDC 토큰 → Azure access token 교환 |
| `hashicorp/setup-terraform@v3` | Terraform CLI 설치 |
| `ARM_*` 환경변수 | azurerm provider/backend가 자동으로 읽는 인증 정보 |
| `terraform init -backend-config=...` | partial backend에 값 채워서 초기화 |

### 두 워크플로우의 차이

| 항목 | plan | apply |
|---|---|---|
| 트리거 | `pull_request` | `push: branches: [main]` |
| Federated credential subject | `repo:OWNER/REPO:pull_request` | `repo:OWNER/REPO:ref:refs/heads/main` |
| 권한 추가 | `pull-requests: write` (코멘트용) | (없음, 최소 권한) |
| 동시성 제어 | 불필요 (read-only) | `concurrency` 그룹 필수 |
| 마지막 명령 | `terraform plan` | `plan -out=tfplan` → `apply tfplan` |
| 결과 | 미리보기만 | 실제 반영 |

---

## 3-1. `terraform-plan.yml`

```bash
mkdir -p /Users/dawn/azure-infra/.github/workflows
```

`.github/workflows/terraform-plan.yml`:

```yaml
name: Terraform Plan

on:
    pull_request:
        branches: [main]
        paths:
            - "terraform/**"
            - ".github/workflows/terraform-plan.yml"

permissions:
    id-token: write       # OIDC 토큰 발급
    contents: read        # 코드 체크아웃
    pull-requests: write  # PR에 결과 코멘트 (선택)

defaults:
    run:
        working-directory: terraform

jobs:
    plan:
        name: terraform plan
        runs-on: ubuntu-latest

        env:
            ARM_USE_OIDC:        "true"
            ARM_CLIENT_ID:       ${{ vars.AZURE_CLIENT_ID }}
            ARM_TENANT_ID:       ${{ vars.AZURE_TENANT_ID }}
            ARM_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}

        steps:
            - name: Checkout
              uses: actions/checkout@v4

            - name: Azure Login (OIDC)
              uses: azure/login@v2
              with:
                  client-id:       ${{ vars.AZURE_CLIENT_ID }}
                  tenant-id:       ${{ vars.AZURE_TENANT_ID }}
                  subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

            - name: Setup Terraform
              uses: hashicorp/setup-terraform@v3
              with:
                  terraform_version: "1.10.0"
                  terraform_wrapper: false

            - name: Terraform fmt check
              run: terraform fmt -check -recursive

            - name: Terraform init
              run: |
                  terraform init \
                    -backend-config="resource_group_name=${{ vars.TFSTATE_RESOURCE_GROUP }}" \
                    -backend-config="storage_account_name=${{ vars.TFSTATE_STORAGE_ACCOUNT }}" \
                    -backend-config="container_name=${{ vars.TFSTATE_CONTAINER }}" \
                    -backend-config="key=terraform.tfstate"

            - name: Terraform validate
              run: terraform validate

            - name: Terraform plan
              id: plan
              run: |
                  set -o pipefail
                  terraform plan -no-color -input=false | tee plan_output.txt

            - name: Write plan to PR summary
              if: always()
              run: |
                  {
                      echo "## 📋 Terraform Plan"
                      echo ""
                      echo '```hcl'
                      cat plan_output.txt
                      echo '```'
                  } >> "$GITHUB_STEP_SUMMARY"
```

### 줄별 설명

#### `on:` — 트리거

```yaml
on:
    pull_request:
        branches: [main]
        paths:
            - "terraform/**"
            - ".github/workflows/terraform-plan.yml"
```

- **`pull_request`**: PR이 열리거나, 새 commit이 push되거나, reopen될 때 트리거.
- **`branches: [main]`**: main을 향한 PR만. 다른 브랜치 간 PR은 무시.
- **`paths:`**: terraform 코드나 이 워크플로우 파일이 바뀐 경우만 실행. README만 수정한 PR로 plan 안 돌게 — 시간/비용 절약.

#### `permissions:` — OIDC의 핵심

```yaml
permissions:
    id-token: write
    contents: read
    pull-requests: write
```

- **`id-token: write`**: ⭐ **이게 있어야 GitHub이 OIDC 토큰을 발급해줍니다.** 없으면 azure/login이 토큰을 못 받음 → 인증 실패.
- **`contents: read`**: 코드 checkout 권한.
- **`pull-requests: write`**: PR에 코멘트 달 때 필요. 지금은 step summary만 쓰니까 엄밀히는 없어도 되지만, 나중에 코멘트 기능 추가할 수 있게 켜둠.

> Permissions를 명시적으로 적으면, 적은 것 외엔 다 빼앗긴 상태가 돼서 안전. **최소 권한 원칙**.

#### `defaults: run: working-directory: terraform`

매 step마다 `cd terraform` 안 적어도 되게 기본 작업 디렉토리 설정.

#### `env:` — provider가 자동으로 읽는 환경변수

```yaml
env:
    ARM_USE_OIDC:        "true"
    ARM_CLIENT_ID:       ${{ vars.AZURE_CLIENT_ID }}
    ARM_TENANT_ID:       ${{ vars.AZURE_TENANT_ID }}
    ARM_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

- azurerm provider와 backend 둘 다 `ARM_*` 환경변수를 자동으로 읽음 → 코드(`providers.tf`, `backend.tf`)에 인증 정보를 안 적어도 됨.
- `vars.*` 참조 → 1단계 1-5에서 등록한 GitHub repository variables.
- **시크릿 안 씀** (OIDC라서). 그래서 `secrets.*`가 아니라 `vars.*`.

#### `azure/login@v2` (OIDC 모드)

```yaml
- name: Azure Login (OIDC)
  uses: azure/login@v2
  with:
      client-id:       ${{ vars.AZURE_CLIENT_ID }}
      tenant-id:       ${{ vars.AZURE_TENANT_ID }}
      subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

- `client-secret`이 **없으면** OIDC 모드로 동작. (있으면 SP+secret 모드)
- 이 step이 끝나면 az CLI도 인증된 상태가 됨. 워크플로우 안에서 `az ...` 명령도 그냥 쓸 수 있음.
- 사실 `ARM_*` 환경변수만으로도 terraform은 인증되니까 이 step이 필수는 아니지만, 디버깅이나 az 명령을 같이 쓸 수 있어서 보통 같이 둠.

#### `hashicorp/setup-terraform@v3`

```yaml
- uses: hashicorp/setup-terraform@v3
  with:
      terraform_version: "1.10.0"
      terraform_wrapper: false
```

- **`terraform_version`**: 어떤 버전을 깔지. `versions.tf`의 `required_version`과 호환되어야 함. 명시적으로 지정해서 매번 다른 버전이 안 깔리게.
- **`terraform_wrapper: false`**: wrapper를 끄면 `terraform plan`의 stdout이 그대로 step에 흘러서 `tee`나 redirect로 바로 캡처 가능. 켜져 있으면 `${{ steps.plan.outputs.stdout }}` 같은 식으로 접근해야 해서 번거로움.

#### `terraform fmt -check -recursive`

코드가 표준 포맷으로 정렬돼있는지 검사. 안 맞으면 비-zero 종료해서 워크플로우 실패. PR 단계에서 잡히면 본인이 `terraform fmt`로 고치면 됨.

#### `terraform init` — `vars.*`에서 backend config 채움

로컬에서 환경변수로 채웠던 partial backend config를, CI에서는 GitHub variables로 채움. backend.tf에 적어두지 않은 이유가 여기서 살아남.

#### `terraform plan -no-color -input=false`

- **`-no-color`**: ANSI 색깔 코드 빼고 출력. 로그/summary에 깔끔하게 들어가게.
- **`-input=false`**: 변수 값을 묻는 인터랙티브 프롬프트 차단. CI는 인터랙션 없는 환경.
- **`set -o pipefail`**: pipe로 연결된 명령들 중 하나라도 실패하면 전체 실패. 안 쓰면 `terraform plan`이 실패해도 `tee`가 성공하니 step이 통과해버림.

#### Step summary에 plan 결과 첨부

```yaml
- name: Write plan to PR summary
  if: always()
  run: |
      {
          echo "## 📋 Terraform Plan"
          echo ""
          echo '```hcl'
          cat plan_output.txt
          echo '```'
      } >> "$GITHUB_STEP_SUMMARY"
```

- **`if: always()`**: plan이 실패해도 결과는 보여주려고. 디버깅에 유용.
- **`$GITHUB_STEP_SUMMARY`**: 여기에 markdown을 쓰면 GitHub Actions 실행 페이지에 예쁘게 렌더링됨. PR 페이지 → Checks 탭 → 워크플로우 클릭 → 상단에 표시.

> 나중에 PR 코멘트로 직접 달고 싶으면 `actions/github-script`나 `peter-evans/create-or-update-comment` 액션을 추가하면 됨.

---

## 3-2. `terraform-apply.yml`

`.github/workflows/terraform-apply.yml`:

```yaml
name: Terraform Apply

on:
    push:
        branches: [main]
        paths:
            - "terraform/**"
            - ".github/workflows/terraform-apply.yml"
    workflow_dispatch:   # GitHub UI에서 수동 실행도 허용

permissions:
    id-token: write
    contents: read

concurrency:
    group: terraform-apply
    cancel-in-progress: false

defaults:
    run:
        working-directory: terraform

jobs:
    apply:
        name: terraform apply
        runs-on: ubuntu-latest

        env:
            ARM_USE_OIDC:        "true"
            ARM_CLIENT_ID:       ${{ vars.AZURE_CLIENT_ID }}
            ARM_TENANT_ID:       ${{ vars.AZURE_TENANT_ID }}
            ARM_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}

        steps:
            - name: Checkout
              uses: actions/checkout@v4

            - name: Azure Login (OIDC)
              uses: azure/login@v2
              with:
                  client-id:       ${{ vars.AZURE_CLIENT_ID }}
                  tenant-id:       ${{ vars.AZURE_TENANT_ID }}
                  subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

            - name: Setup Terraform
              uses: hashicorp/setup-terraform@v3
              with:
                  terraform_version: "1.10.0"
                  terraform_wrapper: false

            - name: Terraform init
              run: |
                  terraform init \
                    -backend-config="resource_group_name=${{ vars.TFSTATE_RESOURCE_GROUP }}" \
                    -backend-config="storage_account_name=${{ vars.TFSTATE_STORAGE_ACCOUNT }}" \
                    -backend-config="container_name=${{ vars.TFSTATE_CONTAINER }}" \
                    -backend-config="key=terraform.tfstate"

            - name: Terraform plan (saved)
              run: terraform plan -no-color -input=false -out=tfplan

            - name: Terraform apply
              run: terraform apply -no-color -input=false tfplan

            - name: Write apply summary
              if: always()
              run: |
                  {
                      echo "## ✅ Terraform Apply"
                      echo ""
                      echo "Commit: \`${{ github.sha }}\`"
                      echo "Triggered by: ${{ github.actor }}"
                  } >> "$GITHUB_STEP_SUMMARY"
```

### plan 워크플로우와 다른 점

#### 1) 트리거 — `push` + `workflow_dispatch`

```yaml
on:
    push:
        branches: [main]
        paths: [...]
    workflow_dispatch:
```

- **`push: branches: [main]`**: PR이 머지되면 결과적으로 main에 push가 일어나서 트리거됨.
- **`workflow_dispatch`**: GitHub UI의 Actions 탭에서 **버튼으로 수동 실행** 가능. 코드 변경 없이 apply를 다시 돌리고 싶을 때 (예: drift 보정).

#### 2) `permissions`에서 `pull-requests: write` 제거

apply는 PR과 무관하므로 PR 코멘트 권한 불필요. **최소 권한 원칙**.

#### 3) `concurrency` — 동시 실행 방지

```yaml
concurrency:
    group: terraform-apply
    cancel-in-progress: false
```

- **왜 필요?** main에 commit이 연속해서 들어가면 apply 워크플로우가 동시에 두 번 돌 수 있음. Terraform state lock이 한쪽을 막아주긴 하지만, 그건 안전망일 뿐 자원 낭비.
- **`group: terraform-apply`**: 같은 group 이름이 붙은 실행은 한 번에 하나만.
- **`cancel-in-progress: false`**: 진행 중인 apply를 **중단하지 않음**. 새 실행은 큐에 넣어 기다리게 함. apply 도중 강제로 취소되면 state가 어중간한 상태가 될 수 있어서 절대 cancel 하면 안 됨.

> plan 쪽엔 `concurrency`를 안 넣었음. plan은 read-only라 동시 실행해도 안전, 오히려 cancel-in-progress: true로 옛날 PR commit의 plan은 취소하는 게 자연스러움.

#### 4) plan + apply를 **분리해서** 실행 (saved plan 패턴)

```yaml
- run: terraform plan ... -out=tfplan
- run: terraform apply ... tfplan
```

`-out=tfplan`으로 plan 결과를 **파일로 저장**한 뒤, apply는 그 파일을 그대로 실행합니다. 그냥 `terraform apply -auto-approve`도 되긴 하지만 saved plan 방식이 더 안전:

| 방식 | 동작 | 위험 |
|---|---|---|
| `apply -auto-approve` | apply가 내부적으로 plan을 다시 만들고 바로 실행 | plan~apply 사이 짧은 순간에 외부 변경이 있으면 의도와 다른 변경이 적용될 수 있음 |
| `plan -out=tfplan` → `apply tfplan` | plan 결과를 **파일로 잠가서** 정확히 그 변경만 적용 | 사이에 외부 변경이 있어도 plan에 없던 건 안 함 (drift는 다음 plan에서 잡힘) |

`-auto-approve`가 안 보이는 이유: 저장된 plan 파일을 받으면 Terraform이 **자동으로 승인된 것으로 간주** (사람이 plan을 보고 저장했다는 가정).

#### 5) Step summary 내용

apply는 plan 본문보단 "**무엇이 어떤 commit으로 적용됐는가**" 같은 메타데이터가 더 의미 있음. 그래서 commit SHA + 실행자만 표시. 원하면 plan 본문도 같이 첨부 가능.

---

## 3-3. 첫 PR로 plan 워크플로우 검증

### 흐름

```text
[현재] 워크플로우 파일들이 로컬에만 있음
   │
   ├─ ① 새 브랜치 만들기
   ├─ ② commit + push
   ├─ ③ PR 만들기
   ▼
[plan 워크플로우 자동 실행 → Checks 탭에서 결과 확인]
   │
   ├─ ④ PR 머지
   ▼
[apply 워크플로우 자동 실행 → main에 적용]
```

같은 repo 안의 PR이면 GitHub Actions는 **PR head 브랜치의 워크플로우 파일**을 사용합니다. 그래서 워크플로우 파일 자체를 PR로 올려도 그 PR에서 실행돼서 검증이 됩니다.

### 명령

```bash
cd /Users/dawn/azure-infra

# 1) 현재 브랜치 확인
git branch --show-current

# main이라면 새 브랜치로:
git checkout -b feat/add-gh-actions

# 2) 변경 사항 확인
git status

# 3) commit
git add .github/ docs/
git commit -m "Add GitHub Actions workflows for terraform plan/apply"

# 4) push
git push -u origin feat/add-gh-actions

# 5) PR 만들기
gh pr create --fill
# --fill: commit 메시지를 PR 제목/본문으로 자동 사용
```

### 워크플로우 실행 확인

```bash
# 브라우저에서 PR 열기
gh pr view --web

# CLI로 최근 워크플로우 실행 보기
gh run list --workflow="Terraform Plan" --limit 3

# 특정 실행 라이브 watch
gh run watch
```

### Checks 탭에서 봐야 할 것

PR 페이지 상단 → **Checks** 탭 → "Terraform Plan" 워크플로우 클릭:

1. ✅ 모든 step이 초록색
2. **Summary** 섹션에 "📋 Terraform Plan" 박스 → `Plan: 0 to add, 0 to change, 0 to destroy` 표시
3. Outputs는 "이미 적용된 값과 같음"이라 변경 없음

---

## 3-4. PR 머지 → apply 워크플로우 검증

### PR 머지

```bash
gh pr merge --squash --delete-branch
```

- **`--squash`**: PR commits를 하나로 합쳐서 main에 머지. main 히스토리가 깔끔해짐.
- **`--delete-branch`**: 머지 후 브랜치 자동 삭제.

### apply 워크플로우 자동 실행 확인

```bash
gh run list --workflow="Terraform Apply" --limit 3
gh run watch
```

### 기대 결과

이번 PR은 terraform 코드가 안 바뀌었고 워크플로우만 추가됐으니 변경 사항 0:

```text
Plan: 0 to add, 0 to change, 0 to destroy.
Apply complete! Resources: 0 added, 0 changed, 0 destroyed.

Outputs:
client_object_id  = "..."
subscription_id   = "..."
subscription_name = "..."
```

**Apply가 0인데 의미 있나?** — 있음. 다음을 검증한 셈:

- ✅ OIDC 인증 (SP)
- ✅ State backend 잠금/읽기/쓰기
- ✅ saved plan → apply 흐름

다음 PR에서 실제 리소스를 추가하면 그땐 변경이 잡힐 것.

### State 일치 확인 (선택)

```bash
cd /Users/dawn/azure-infra/terraform
git pull   # main 업데이트 받기

terraform output

# state 파일 메타
terraform state pull | jq '.serial, .lineage'
# serial이 apply 후 증가했으면 backend 동작 OK
```

---

## (선택) 수동 승인 게이트 추가하기

지금은 main에 머지되면 **자동으로 apply**가 돕니다. 운영 환경에서는 사람 승인 한 번 받고 싶을 수 있어요. 그럴 땐:

1. GitHub repo → **Settings → Environments → New environment** → 이름 예: `azure`
2. 그 environment에 **Required reviewers** 룰 추가 (본인 또는 팀원)
3. apply 워크플로우 job에 한 줄 추가:

   ```yaml
   jobs:
       apply:
           environment: azure   # ← 이 한 줄
           ...
   ```

4. (보안 강화) 1단계의 federated credential도 environment subject로 더 좁히기:
   - subject: `repo:OWNER/REPO:environment:azure`
   - 이러면 environment를 거치지 않은 워크플로우에서는 OIDC 인증 자체가 거부됨

이러면 apply는 main push 시점에 **대기 상태**로 멈추고, 승인자가 GitHub에서 "Approve" 클릭해야 진행됩니다.

---

## 자주 만나는 에러

### `Error: failed to acquire OIDC token`

**원인**:

- `permissions: id-token: write` 빠짐
- federated credential subject가 현재 컨텍스트와 안 맞음

**해결**:

```bash
# subject가 정확히 들어갔는지
az ad app federated-credential list --id $CLIENT_ID -o table

# pull_request 워크플로우에서 났으면 → "repo:OWNER/REPO:pull_request" 있어야 함
# main push 워크플로우에서 났으면 → "repo:OWNER/REPO:ref:refs/heads/main" 있어야 함
```

### `Error: 403 AuthorizationPermissionMismatch` (storage backend)

**원인**: SP에 `Storage Blob Data Contributor` 권한 없음.

**해결**: 2단계 2-7 ① 단계의 SP grant 명령 다시 확인. Subscription scope의 Contributor만으로는 data plane 접근 불가.

### 워크플로우가 **아예 트리거 안 됨**

**원인**: `paths` 필터에 안 걸림.

**해결**:

- plan: `paths: ["terraform/**", ".github/workflows/terraform-plan.yml"]`
- apply: `paths: ["terraform/**", ".github/workflows/terraform-apply.yml"]`

위 경로 외 파일만 변경하면 트리거 안 됨 (의도된 동작). README 같은 거만 바꾸고 강제로 워크플로우 실행하고 싶으면 `workflow_dispatch`로 수동 실행.

### YAML `Implicit map keys need to be followed by map values`

**원인**: 콜론(`:`) 빠짐 또는 들여쓰기 어긋남.

```yaml
# ❌ 콜론 빠짐
ARM_SUBSCRIPTION_ID ${{ vars.AZURE_SUBSCRIPTION_ID }}

# ✅
ARM_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

들여쓰기는 한 칸만 어긋나도 의미가 완전히 바뀝니다. `env:`, `steps:`가 `jobs.<job-name>:`의 자식인지 (들여쓰기 한 단계 더 들어가있는지) 확인.

### VSCode에서 자동완성이 안 됨

**해결**: GitHub Actions 익스텐션 설치

- 명령 팔레트(`Cmd+Shift+P`) → `Extensions: Install Extensions` → "GitHub Actions" 검색 → `github.vscode-github-actions` 설치
- 설치 후 `uses:`, `runs-on:` 등 자동완성 + 인라인 스키마 검증

---

## 완료 체크리스트

- [ ] `.github/workflows/terraform-plan.yml` 작성 — pull_request 트리거
- [ ] `.github/workflows/terraform-apply.yml` 작성 — push to main 트리거
- [ ] PR 생성 시 plan 워크플로우 자동 실행, Checks 탭의 Summary에 plan 출력 표시
- [ ] PR 머지 시 apply 워크플로우 자동 실행, `Apply complete!` 출력
- [ ] state file이 Azure Storage에 정상 업데이트되고 serial이 증가

---

## 다음에 할 만한 것

1. **첫 실제 리소스 추가** — Resource Group 하나를 PR로 올려서 plan/apply가 진짜 변경을 잡는지 검증
2. **Apply에 수동 승인 게이트** — GitHub Environment 설정
3. **Module화** — 리소스가 늘면 `modules/` 디렉토리로 분리
4. **변수/환경 분리** — prod가 생기면 `environments/dev/`, `environments/prod/` 같은 디렉토리 패턴
5. **Drift detection** — 매일 cron으로 plan만 돌려 외부 변경 감지
