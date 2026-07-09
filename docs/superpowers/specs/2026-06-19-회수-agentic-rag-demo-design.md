# 회수 도메인 2-tool Agentic RAG 데모 — 설계서

- 작성일: 2026-06-19
- 상태: 설계 확정 (구현 대기)
- 선행: `05_Phase3_구현/autoever_demo/` 기존 4테이블 데모(E2E 성공)를 8테이블 회수 도메인으로 교체

---

## 1. 목적 (제품 관점)

이 데모의 진짜 목적은 **"Postgres MCP(데이터) + LightRAG(지식) 2-tool agentic RAG"가 제품이 될 수 있는가**를 보이는 것. 현대캐피털 회수 도메인은 그걸 보여줄 **무대(연출)**일 뿐, 현 HCS Code2Rule 프로젝트(레거시 역문서화)와는 분리한다.

- **역문서화는 적용하지 않는다.** 그것은 HCS 프로젝트 한정 입력방식. 제품의 LightRAG에는 **회수 규정/약관**(손으로 작성)이 들어간다. 실제 회수 담당자도 역문서가 아니라 규정집을 본다.
- **제품 한 줄 정의:** *운영 담당자 코파일럿 — "이 건 실제로 어떤가(데이터)" + "규정상 어떻게 해야 하나(지식)"를 한 번에 묻고, 둘을 대조해 갭/조치를 짚어준다.*
- **제품성 근거:** 도메인 무관하게 같은 모양("트랜잭션 데이터 + 사내 규정/매뉴얼"). 회수는 모든 여신/할부사가 가진 보편 업무라 일반화가 된다.

**성공 기준:** OpenCode 에이전트가 한 질의에 대해 자율로 Postgres MCP와 LightRAG 둘 다 호출 → 대조 → 규정 위반 갭을 라인(계약ID·금액·근거규정)까지 짚어낸다. 한쪽 툴만으론 못 나오는 답이어야 한다.

---

## 2. 아키텍처

```
OpenCode 에이전트 (AGENTS.md = 갭지적·근거분리 지침)
   │
   ├── Postgres MCP (자작 postgres-mcp, read pg_query + write pg_execute)
   │        └── demo_legacy DB / 회수 도메인 8테이블  ← "실제로 어떤가"
   │
   └── LightRAG MCP (자작 lightrag-mcp 래퍼, include_references)
            └── 회수 규정 5장                          ← "규정상 어떻게"
```

- **플러밍은 기존 것 재사용.** `opencode.json`(postgres-mcp + lightrag-mcp), `lightrag-mcp/`, `postgres-mcp/`, SSH 터널(`-L 15432:localhost:5434`) 구성 그대로.
- **인프라:** VPS `193.168.195.222`. Postgres 컨테이너 `postgres-vector`(호스트 5434), DB `demo_legacy`(기존, pylon_dev 안 건드림). LightRAG `http://193.168.195.222:9621`(auth disabled).
- 교체 대상은 **콘텐츠뿐**: 데이터 SQL, 규정 마크다운, AGENTS.md 시연 시나리오, SETUP 런북.

---

## 3. 데이터 모델 — Postgres 8테이블 (회수 도메인)

| 테이블 | 역할 | 비고 |
|--------|------|------|
| `customer` | 고객 (등급 VIP/일반·신용점수·소득·DTI) | 기존 유지, 2000행 |
| `product` | 상품 + **연체이자율·중도상환수수료율** | 기존 + 컬럼 추가, 8행 |
| `loan_contract` | 계약 (원금·금리·약정개월·상태) | 기존 유지, 3000행 |
| `repayment_schedule` 🆕 | 월 상환 스케줄 (회차·납기·원금·이자·총액·상태) | 계약별 분할표 |
| `billing` 🆕 | 월 청구 (청구년월·청구유형·청구액·납기·상태) | 위약금도 청구유형으로 흡수 |
| `deposit` 🆕 | 입금 내역 (입금일·금액·방법·**NSF여부**) | 자동이체/가상계좌 |
| `deposit_detail` 🆕 | 입금 상세 = 충당 (충당유형·**충당순서**·금액) | 충당 우선순위 검증용 |
| `delinquency` 🆕 | 연체 (연체시작·연체일수·연체원금·연체이자·단계) | NSF→연체전환 검증용 |

> `fee(수수료)`·`refund(환불)`은 별도 테이블 대신 `billing.bill_type`(중도해지위약금 등)과 `deposit_detail.alloc_type`(수수료/환불 충당)으로 흡수 → 8테이블 유지.

### 3.1 주요 컬럼 (확정 골격, 정밀 타입은 구현 플랜에서)

- `product`: `product_code, product_name, product_type, auto_approve_yn, max_dti, **delinquent_rate**(연체이자율%), **prepay_fee_rate**(중도상환수수료율%)`
- `repayment_schedule`: `schedule_id, contract_id, installment_no, due_date, principal_due, interest_due, total_due, status('예정'|'완납'|'연체')`
- `billing`: `billing_id, contract_id, bill_ym, bill_type('정기'|'연체이자'|'중도해지위약금'), amount, due_date, status('미납'|'완납')`
- `deposit`: `deposit_id, contract_id, paid_date, amount, method('자동이체'|'가상계좌'), **nsf_yn**('Y'|'N')`
- `deposit_detail`: `detail_id, deposit_id, alloc_type('연체이자'|'이자'|'원금'|'수수료'), **alloc_seq**(충당 순서 1..n), amount`
- `delinquency`: `delinquency_id, contract_id, start_date, overdue_days, overdue_principal, overdue_interest, stage('1단계'|'2단계'|'3단계')`

데이터는 전부 **합성**(`generate_series`), VPS에서 `docker exec -i postgres-vector psql -U postgres -d demo_legacy < ...sql`로 멱등 적재.

---

## 4. LightRAG 지식 — 회수 규정 5장 (손으로 작성)

| # | 규정 문서 | 핵심 내용 | 연결 갭 |
|---|-----------|-----------|---------|
| 1 | 청구 산정 규정 | 월 청구액 = 원금 + 이자 (+연체이자 +수수료) | — |
| 2 | **입금 충당 우선순위** | 연체이자 → 이자 → 원금 → 수수료 순 | 갭1 |
| 3 | 연체 처리 단계 | 연체일수별 1/2/3단계·연체이자율 적용 | — |
| 4 | **NSF(자동이체 실패) 처리** | 출금 실패 시 **익일 연체 전환** + 재청구 | 갭2 |
| 5 | 중도해지·환불 정산 (VIP 위약금 면제) | 중도해지 위약금 = 잔여원금 2%, **단 VIP 전액 면제** | 갭3 |

LightRAG 적재는 `/documents/upload`(multipart) 또는 래퍼 ingest. KB는 **이 5장만** 깨끗이 유지(기존 PoC junk·옛 규칙 잔존분은 `clean_kb.mjs`로 정리 후 재적재).

---

## 5. 심을 갭 3개 — 킬러 시연 (둘 다 써야만 답)

각 갭은 기존 VIP 갭처럼 **결정적(deterministic) predicate**로 심어 건수가 SQL로 검증 가능해야 한다.

### 갭1 — 입금 충당 순서 위반
- **규정(LightRAG 규정2):** 연체이자 → 이자 → 원금 → 수수료 순 충당.
- **데이터(Postgres):** 연체이자 잔액이 있는데도 `deposit_detail`에서 **원금의 `alloc_seq`가 연체이자보다 앞선** 입금 건을 결정적 subset에 심음.
- **킬러질의:** "이번달 입금 중 충당 순서 규정 위반 건?"
- **기대 답:** 위반 deposit_id 목록 + "규정상 연체이자 우선인데 원금부터 충당됨" + 건수.

### 갭2 — NSF → 연체 전환 누락
- **규정(LightRAG 규정4):** NSF면 익일 연체 전환(`delinquency` 행 생성).
- **데이터(Postgres):** `deposit.nsf_yn='Y'`인데 해당 계약에 `delinquency` 행이 **없는** 건을 결정적 subset에 심음.
- **킬러질의:** "NSF인데 연체 전환 안 된 계약?"
- **기대 답:** 누락 contract_id 목록 + "NSF 규정상 익일 연체전환 대상인데 delinquency 부재" + 건수.

### 갭3 — VIP 중도해지 위약금 오부과 (기존 갭 계승)
- **규정(LightRAG 규정5):** VIP는 중도해지 위약금 전액 면제.
- **데이터(Postgres):** 중도해지 VIP 계약 중 결정적 subset(`contract_id % 3 = 0`)에 `billing(bill_type='중도해지위약금', amount>0)` 부과.
- **킬러질의:** "이번 분기 중도해지 중 위약금 정책 위반 건?"
- **기대 답:** 위반 계약·금액 라인 + "VIP 면제 대상인데 부과됨" + 합계.

> 갭마다 에이전트는 **「근거」 블록**으로 출처를 분리 출력: `[데이터·Postgres]`(테이블·조건·행ID) / `[규정·LightRAG]`(출처 문서명). AGENTS.md에 의무화(기존 지침 계승).

---

## 6. 기존 데모에서의 변경 (재사용 vs 교체)

| 항목 | 처리 |
|------|------|
| `opencode.json`, `postgres-mcp/`, `lightrag-mcp/`, SSH 터널 | **재사용** (변경 없음) |
| `data/01_demo_data.sql` (4테이블) | **교체** → 8테이블 회수 도메인 |
| `rules/규칙_01~03.md` (3장) | **교체** → 회수 규정 5장 |
| `AGENTS.md` | **갱신** → 회수 시연 시나리오·근거블록 유지 |
| `SETUP.md` | **갱신** → 8테이블 적재·규정5장 ingest 런북 |
| LightRAG KB junk | `clean_kb.mjs`로 정리 후 규정 5장만 적재 |

---

## 7. 범위 밖 (YAGNI)

- 실제 배치 프로시저 구현(스케줄/청구 생성 로직) — 합성 데이터로 결과만 표현, 로직은 규정 문서로 설명.
- fee/refund 독립 테이블 — billing/deposit_detail에 흡수.
- 실데이터(Lending Club 등) 이행 — 전량 합성.
- 에이전트 런타임 다변화 — OpenCode 고정(필요 시 n8n AI Agent는 후속).

---

## 8. 미결 (구현 플랜에서 확정)

- `generate_series` 정확한 분포/건수(스케줄·청구·입금·충당·연체 각 테이블 행수 상한).
- 각 갭 결정적 predicate의 정확한 모듈로 값(겹침 없이 검증 쿼리로 건수 떨어지게).
- 충당 순서 표현 방식 최종(`alloc_seq` 정수 vs 별도 우선순위 컬럼).

---

## 9. 다음 단계

이 설계 승인 → `writing-plans` 스킬로 구현 플랜 작성 → 구현 순서: ①8테이블 DDL+합성SQL → ②회수 규정 5장 → ③KB 청소+적재 → ④AGENTS.md/SETUP 갱신 → ⑤킬러질의 3종 E2E 검증.
