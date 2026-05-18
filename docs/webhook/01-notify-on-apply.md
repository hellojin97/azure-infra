# Webhook: Terraform Apply 결과 Discord 알림

azure-infra의 `terraform-apply.yml` 워크플로우가 끝나면 결과(success/failure/cancelled)를 Discord 채널로 알림. **본 repo 자체 운영을 위한 알림** — Lakeflow → Discord 중계용 Function App (별도 repo `python-discord-webhook-app`)와는 완전히 분리.

이 문서를 읽기 전에:
- [03-github-actions.md](../03-github-actions.md) — terraform-apply.yml의 base 구조
- 액션 자체의 입력/동작/함정 reference: [02-sarisia-action-reference.md](02-sarisia-action-reference.md)

> 완료일: 2026-05-19. PR #11 merge 직후 자가-검증된 첫 알림.

---

## 결과 요약

| 항목 | 값 |
|---|---|
| 알림 대상 | azure-infra `terraform-apply.yml` 마지막 step |
| 알림 채널 | 별도 Discord webhook (azure-infra 전용) |
| 알림 조건 | success + failure 둘 다 (`if: always()`) |
| 구현 방식 | `sarisia/actions-status-discord@v1` (4줄) |
| Secret | `AZURE_INFRA_DISCORD_WEBHOOK_URL` |

---

## 1. 왜 알림을 만들었나

terraform-apply.yml은 main push 또는 workflow_dispatch로 자동 실행. 로컬 셸에서 `gh run watch`를 매번 띄우지 않으면 결과를 놓치기 쉬움. 특히:

- **race condition 같은 의도치 않은 변경**: Phase 4 진행 중 `terraform apply`와 `deploy.yml`이 같은 App Setting을 race 해서 운영이 깨진 사건이 있었음 ([python-discord-webhook-app의 docs/06 §4-8](https://github.com/hellojin97/python-discord-webhook-app/blob/main/docs/06-phase4-keyvault-migration.md) 참고). 알림이 있었다면 즉시 인지 가능.
- **drift fix가 자동 돈 경우**: 외부에서 누군가 portal로 인프라를 건드린 다음 apply가 또 돌면, 그 사실을 알아채야 함.
- **success 알림도 가치 있음**: "방금 변경이 결국 무사히 들어감"이라는 시각적 closure. 매번 console 확인하지 않아도 됨.

---

## 2. 구조 — 어디에 무엇이 들어가나

### 2-1. `.github/workflows/terraform-apply.yml`

기존 마지막 step "Write apply summary" 뒤에 한 step 추가:

```yaml
            - name: Notify Discord
              uses: sarisia/actions-status-discord@v1
              if: always()
              with:
                webhook: ${{ secrets.AZURE_INFRA_DISCORD_WEBHOOK_URL }}
                title:   Terraform Apply
```

각 줄 의미는 [§02-sarisia-action-reference.md](02-sarisia-action-reference.md)에 풀로 정리. 핵심 4가지만:

| 줄 | 핵심 |
|---|---|
| `uses: sarisia/actions-status-discord@v1` | major tag pinning. v1.x latest 자동. lab엔 충분. |
| `if: always()` | apply step이 fail해도 알림 실행. **빼면 failure 알림 절대 안 옴**. |
| `webhook: ${{ secrets.AZURE_INFRA_DISCORD_WEBHOOK_URL }}` | URL을 코드/로그에 평문 노출 안 시킴. masking은 GitHub Actions 자동. |
| `title: Terraform Apply` | embed 제목 라벨. 안 주면 default가 워크플로우 이름. |

### 2-2. GitHub secret 등록

```bash
gh secret set AZURE_INFRA_DISCORD_WEBHOOK_URL --repo hellojin97/azure-infra
# Paste your secret. Press Ctrl+D to finish.
# → URL 한 줄 붙여넣고 Enter, 그 다음 Ctrl+D
```

⚠️ **`--body 'URL...'` 인자 방식 금지**. quote/공백 오타가 webhook URL을 셸 history에 평문으로 남기는 사고가 한 번 있었음. interactive prompt 또는 stdin 사용.

---

## 3. 핵심 의사결정

### 3-1. 직접 curl vs 액션 사용

| 안 | 내용 | 채택 |
|---|---|---|
| (A) curl + jq로 직접 호출 | payload schema 풀 컨트롤. yaml 40줄. HTTP/JSON/Discord API 직접 학습 | |
| (B) `sarisia/actions-status-discord@v1` | yaml 4-6줄. status/color/context fields 자동. 유지보수 0 | ✅ |

**왜 (B):**
- lab 알림이라 payload 풀 컨트롤 필요 없음
- success/failure embed 색/제목 분기 같은 보일러플레이트가 액션 안에 다 있음
- author sarisia는 ~1.7k★ verified, v1.16.0(2026-01-09)까지 활발 유지보수 — supply chain risk 낮음

### 3-2. 알림 조건: success + failure 둘 다 (`if: always()`)

| 안 | 내용 | 채택 |
|---|---|---|
| (X) success + failure 둘 다 | 변경 빈도 낮은 lab. success도 closure 가치 | ✅ |
| (Y) failure만 | 소음 ↓. 단 "조용 = success"라 잠깐 외출하면 변경 사실 인지 안 됨 | |

lab엔 (X). 운영 빈도가 높아지면 (Y) + 일일 summary 같이 패턴 바꿈.

### 3-3. Secret 분리 (Function App webhook과 별개)

| Secret | repo | 용도 |
|---|---|---|
| `AZURE_INFRA_DISCORD_WEBHOOK_URL` | azure-infra | terraform-apply 자체 알림 (이 문서) |
| Key Vault의 `discord-webhook-url` | (Azure KV) | Function App이 Lakeflow → Discord 중계 시 사용 |

같은 Discord 서버라도 채널/webhook은 별개. **알림 목적에 따라 webhook을 분리**해두면 (a) 한쪽이 노출돼도 다른 쪽 영향 없음 (b) Discord UI에서 채널별 mute/볼륨 조절 (c) 로그 추적 가능.

### 3-4. 버전 pinning: `@v1` (major)

| 패턴 | 안정성 | 자동 보안 패치 |
|---|---|---|
| `@v1` (major) | 중 | ✓ — patch/minor 자동 적용 |
| `@v1.16.0` (semver) | 상 | ✗ |
| `@<full-sha>` (commit) | 상상 (supply chain 가드) | ✗ |

lab은 `@v1`. prod로 옮기면 SHA pin 권장.

---

## 4. 검증 — 첫 자가-검증

PR #11 (`feat: notify Discord on terraform-apply outcome`) merge 직후, 그 merge가 트리거한 `terraform-apply.yml`이 첫 알림을 발사. apply success → 초록 embed:

| 필드 | 값 |
|---|---|
| Title | ✅ Success: Terraform Apply |
| Branch | main |
| Commit | (PR #11 merge SHA) |
| Workflow | Terraform Apply |
| Actor | hellojin97 |
| Timestamp | (UTC) |

→ end-to-end 동작 확인 완료.

---

## 5. 만난 함정 (재발 방지)

### 5-1. 처음 curl + jq로 ~40줄 구현하려다 액션 발견

처음엔 curl + jq로 payload 직접 빌드 + color 정수 변환 + 등등 ~40줄 yaml을 제시받음. "github uses로 discord 뭐 있지 않나" 한 질문에 sarisia 액션을 발견 → 4줄로 줄임.

**lesson:** GitHub Actions marketplace는 흔한 알림/통합 패턴엔 거의 다 액션이 있음. yaml 30줄 넘기 전에 marketplace 한 번 search.

### 5-2. PR plan 시간이 좀 걸려서 "멈춤"으로 오인

26개 리소스 refresh + plan에 60초 가까이 걸림. 사용자가 보기엔 "plan 안 넘어감". 단순히 시간이 걸린 것 — 폴링으로 첫 시도(15초)에 completed 확인됨.

**lesson:** "plan 안 넘어감" 같은 정성적 증상은 `gh run view <id> --json status,jobs`로 step별 status 보고 in_progress인지 확인.

### 5-3. 브랜치 이름 vs commit 내용 mismatch

PR #11이 `cleanup/remove-discord-webhook-var` 브랜치에서 만들어졌는데 (PR #10에서 이미 그 브랜치 이름 썼음), 실제 commit은 sarisia notify step 추가. 브랜치 이름 재사용 — 동작엔 문제 없지만 PR list에서 의도 파악이 헷갈림.

**lesson:** 새 의도 = 새 브랜치. `feat/discord-notify-on-apply` 같이 commit 의도와 일치하는 이름.

---

## 6. 다음에 정책 바꾸려면

| 변경 | 명령/방법 |
|---|---|
| webhook URL 회전 | Discord에서 새 webhook 발급 → `gh secret set AZURE_INFRA_DISCORD_WEBHOOK_URL --repo ...` (같은 이름 덮어쓰기). yml 변경 없음. |
| Failure만 알림으로 좁히기 | `if: always()` → `if: failure()`. success는 조용. |
| 다른 워크플로우(예: terraform-plan)에도 알림 | 같은 step을 `terraform-plan.yml`에도 복사. 다만 PR plan은 자주 돌아 noise — 추천 안 함. |
| 알림 실패도 job fail로 다루기 | `with:` 안에 `nofail: false` 추가 |
| custom mention (예: 실패 시 본인 ping) | `content: "Hey <@<userid>> failure"` 추가. status 분기는 step을 둘로 쪼개거나 액션의 자동 분기 활용 |
| 알림 실패 디버깅 (raw payload 보기) | step에 `id: notify` → 후속 step에서 `${{ steps.notify.outputs.payload }}` 출력 |
