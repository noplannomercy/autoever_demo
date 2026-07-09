# 회수 도메인 2-tool Agentic RAG 데모 구현 플랜

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 기존 4테이블 데모를 현대캐피털 회수 도메인 8테이블 + 회수 규정 5장으로 교체하고, 결정적 갭 3종(충당순서/NSF연체전환/VIP위약금)을 심어 2-tool agentic RAG 킬러 시연을 완성한다.

**Architecture:** Postgres MCP(`demo_legacy` 8테이블, 합성데이터=실데이터) + LightRAG MCP(회수 규정 5장=institutional knowledge). OpenCode 에이전트가 두 툴을 교차 호출해 규정 위반 갭을 라인까지 짚는다. 역문서화는 적용 안 함(제품 관점).

**Tech Stack:** PostgreSQL(`generate_series` 합성), LightRAG REST(`/documents`), Node ESM 스크립트(ingest/clean), OpenCode + MCP.

## Global Constraints

- 대상 DB는 `demo_legacy`만. `pylon_dev` 절대 건드리지 않음.
- 모든 데이터는 합성(`generate_series`). 외부 데이터 이행 없음.
- 갭은 전부 **결정적 predicate**로 심어 검증 SQL로 정확한 건수가 떨어져야 함: **갭1=6건, 갭2=5건, 갭3=4건**.
- SQL은 멱등(재실행 시 `DROP ... CASCADE` 후 전체 재생성).
- LightRAG 적재 파일 접두 = `회수규정_` (clean_kb 보존 기준과 일치).
- 적재는 VPS에서 `docker exec -i postgres-vector psql -U postgres -d demo_legacy < 파일.sql` (노트북에 psql 없음). 규정은 `node ingest_rules.mjs`.
- **이 폴더는 git repo가 아님 → commit 단계 없음.** 각 태스크의 완료 경계 = 검증 쿼리/확인 통과.
- 인코딩: Node `readFileSync(..., 'utf-8')` 유지. 한글 콘솔 깨짐은 표시문제일 뿐 무시.

---

## File Structure

| 파일 | 책임 | 처리 |
|------|------|------|
| `data/01_demo_data.sql` | 8테이블 DDL + 합성데이터 + 갭3종 + 검증 SELECT | **재작성** |
| `rules/회수규정_01_청구산정.md` | 월 청구액 산정 규정 | 신규 |
| `rules/회수규정_02_입금충당우선순위.md` | 충당 순서(연체이자→이자→원금→수수료) | 신규 (갭1) |
| `rules/회수규정_03_연체처리단계.md` | 연체일수별 단계·연체이자율 | 신규 |
| `rules/회수규정_04_NSF처리.md` | 자동이체 실패 시 익일 연체전환 | 신규 (갭2) |
| `rules/회수규정_05_중도해지환불정산.md` | 위약금·VIP면제·환불 | 신규 (갭3) |
| `rules/규칙_01~03.md` (기존 3장) | — | **삭제** |
| `rules/clean_kb.mjs` | KB 청소 | `KEEP_PREFIX` 변경 |
| `rules/ingest_rules.mjs` | KB 적재 | 변경 없음(폴더 *.md 자동) |
| `AGENTS.md` | 에이전트 지침·시연 시나리오 | 시나리오 섹션 교체 |
| `SETUP.md` | 런북 | 적재 단계 갱신 |
| `opencode.json`, `postgres-mcp/`, `lightrag-mcp/` | MCP 플러밍 | **재사용(변경 없음)** |

---

## Task 1: 8테이블 스키마 + 합성데이터 + 갭3종 SQL

**Files:**
- Create(재작성): `data/01_demo_data.sql`

**Interfaces:**
- Produces: 테이블 `customer, product, loan_contract, repayment_schedule, billing, deposit, deposit_detail, delinquency`. 갭 검증 컬럼: `deposit.nsf_yn`, `deposit_detail.alloc_seq`, `billing.bill_type='중도해지위약금'`.

- [ ] **Step 1: `data/01_demo_data.sql` 전체를 아래 내용으로 작성**

```sql
-- =====================================================================
-- demo_legacy : 회수 도메인 8테이블 (오토에버 2-tool agentic RAG 데모)
-- 멱등: 재실행 시 전체 재생성
-- ★갭1=충당순서위반(6) / ★갭2=NSF연체전환누락(5) / ★갭3=VIP위약금오부과(4)
-- 적재: docker exec -i postgres-vector psql -U postgres -d demo_legacy < 01_demo_data.sql
-- =====================================================================
BEGIN;

DROP TABLE IF EXISTS deposit_detail     CASCADE;
DROP TABLE IF EXISTS delinquency        CASCADE;
DROP TABLE IF EXISTS deposit            CASCADE;
DROP TABLE IF EXISTS billing            CASCADE;
DROP TABLE IF EXISTS repayment_schedule CASCADE;
DROP TABLE IF EXISTS loan_contract      CASCADE;
DROP TABLE IF EXISTS product            CASCADE;
DROP TABLE IF EXISTS customer           CASCADE;

-- 1) 고객 (2000)
CREATE TABLE customer (
  customer_id   int PRIMARY KEY,
  name          text NOT NULL,
  grade         text NOT NULL,          -- 'VIP' | '일반'
  credit_score  int  NOT NULL,
  annual_income int  NOT NULL,          -- 만원
  dti           numeric(5,2) NOT NULL
);
INSERT INTO customer
SELECT g, '고객'||lpad(g::text,5,'0'),
  CASE WHEN g%10=0 THEN 'VIP' ELSE '일반' END,
  600+(g*7)%250, 3000+(g%50)*200, round(((g%40)+10)::numeric,2)
FROM generate_series(1,2000) g;

-- 2) 상품 (8) + 연체이자율/중도상환수수료율
CREATE TABLE product (
  product_code    text PRIMARY KEY,
  product_name    text NOT NULL,
  product_type    text NOT NULL,        -- 신용대출|담보대출|오토할부|리스
  auto_approve_yn char(1) NOT NULL,
  max_dti         numeric(5,2) NOT NULL,
  delinquent_rate numeric(4,2) NOT NULL,  -- 연체이자율(%)
  prepay_fee_rate numeric(4,2) NOT NULL   -- 중도상환수수료율(%)
);
INSERT INTO product VALUES
 ('P01','직장인신용대출',  '신용대출','Y',40.00,18.00,2.00),
 ('P02','프리미엄신용대출','신용대출','N',50.00,17.00,1.50),
 ('P03','주택담보대출',    '담보대출','N',60.00,12.00,1.20),
 ('P04','오토할부-신차',   '오토할부','Y',45.00,15.00,2.00),
 ('P05','오토할부-중고',   '오토할부','Y',40.00,16.00,2.00),
 ('P06','오토리스',        '리스',    'N',55.00,14.00,1.80),
 ('P07','비상금대출',      '신용대출','Y',35.00,19.00,2.50),
 ('P08','사업자담보대출',  '담보대출','N',65.00,13.00,1.50);

-- 3) 계약 (3000)
CREATE TABLE loan_contract (
  contract_id   int PRIMARY KEY,
  customer_id   int  NOT NULL REFERENCES customer(customer_id),
  product_code  text NOT NULL REFERENCES product(product_code),
  principal     bigint NOT NULL,
  interest_rate numeric(4,2) NOT NULL,
  term_months   int  NOT NULL,
  status        text NOT NULL,          -- 정상|완납|중도해지|연체
  start_date    date NOT NULL
);
INSERT INTO loan_contract
SELECT g, ((g*13)%2000)+1, 'P0'||((g%8)+1),
  ((g%90)+10)*1000000,
  round((3.0+(g%120)/10.0)::numeric,2),
  (ARRAY[12,24,36,48,60])[(g%5)+1],
  CASE WHEN g%7=0 THEN '중도해지'
       WHEN g%11=0 THEN '연체'
       WHEN g%5=0 THEN '완납'
       ELSE '정상' END,
  DATE '2024-01-01'+((g*17)%800)
FROM generate_series(1,3000) g;

-- 4) 월 상환 스케줄 (정상·연체 계약, 6회차)
CREATE TABLE repayment_schedule (
  schedule_id    bigserial PRIMARY KEY,
  contract_id    int NOT NULL REFERENCES loan_contract(contract_id),
  installment_no int NOT NULL,
  due_date       date NOT NULL,
  principal_due  bigint NOT NULL,
  interest_due   bigint NOT NULL,
  total_due      bigint NOT NULL,
  status         text NOT NULL          -- 완납|예정|연체
);
INSERT INTO repayment_schedule (contract_id, installment_no, due_date, principal_due, interest_due, total_due, status)
SELECT lc.contract_id, s.n,
  (DATE '2026-01-10' + (s.n-1)*INTERVAL '1 month')::date,
  round(lc.principal/lc.term_months)::bigint,
  round(lc.principal*lc.interest_rate/100/12)::bigint,
  round(lc.principal/lc.term_months)::bigint + round(lc.principal*lc.interest_rate/100/12)::bigint,
  CASE WHEN (DATE '2026-01-10' + (s.n-1)*INTERVAL '1 month')::date < DATE '2026-06-19'
            THEN CASE WHEN lc.status='연체' AND s.n>=5 THEN '연체' ELSE '완납' END
       ELSE '예정' END
FROM loan_contract lc
CROSS JOIN generate_series(1,6) AS s(n)
WHERE lc.status IN ('정상','연체');

-- 5) 월 청구 (정기 + 중도해지위약금)
CREATE TABLE billing (
  billing_id  bigserial PRIMARY KEY,
  contract_id int NOT NULL REFERENCES loan_contract(contract_id),
  bill_ym     char(6) NOT NULL,         -- YYYYMM
  bill_type   text NOT NULL,            -- 정기|중도해지위약금
  amount      bigint NOT NULL,
  due_date    date NOT NULL,
  status      text NOT NULL             -- 미납|완납
);
-- 5-1) 정기 청구 (정상·연체, 2026-06)
INSERT INTO billing (contract_id, bill_ym, bill_type, amount, due_date, status)
SELECT lc.contract_id, '202606', '정기',
  round(lc.principal/lc.term_months)::bigint + round(lc.principal*lc.interest_rate/100/12)::bigint,
  DATE '2026-06-10',
  CASE WHEN lc.status='연체' THEN '미납' ELSE '완납' END
FROM loan_contract lc WHERE lc.status IN ('정상','연체');
-- 5-2) 중도해지 위약금 ★갭3: VIP 면제 위반(작은 4건 오부과)
INSERT INTO billing (contract_id, bill_ym, bill_type, amount, due_date, status)
SELECT lc.contract_id, '202605', '중도해지위약금',
  CASE
    WHEN c.grade='VIP' AND lc.contract_id IN (
        SELECT lc2.contract_id FROM loan_contract lc2
        JOIN customer c2 ON c2.customer_id=lc2.customer_id
        WHERE lc2.status='중도해지' AND c2.grade='VIP'
        ORDER BY lc2.contract_id LIMIT 4)
      THEN round(lc.principal*0.02)::bigint     -- 갭: 면제대상인데 부과
    WHEN c.grade='VIP' THEN 0                     -- 정상 면제
    ELSE round(lc.principal*0.02)::bigint         -- 일반 정상 부과
  END,
  DATE '2026-05-20', '완납'
FROM loan_contract lc JOIN customer c ON c.customer_id=lc.customer_id
WHERE lc.status='중도해지';

-- 6) 입금 내역 (정상=정상납입, 연체=자동이체 NSF 실패)
CREATE TABLE deposit (
  deposit_id  bigserial PRIMARY KEY,
  contract_id int NOT NULL REFERENCES loan_contract(contract_id),
  paid_date   date,
  amount      bigint NOT NULL,
  method      text NOT NULL,            -- 자동이체|가상계좌
  nsf_yn      char(1) NOT NULL          -- Y=잔액부족 출금실패
);
INSERT INTO deposit (contract_id, paid_date, amount, method, nsf_yn)
SELECT lc.contract_id,
  CASE WHEN lc.status='연체' THEN NULL ELSE DATE '2026-06-10' END,
  CASE WHEN lc.status='연체' THEN 0
       ELSE round(lc.principal/lc.term_months)::bigint + round(lc.principal*lc.interest_rate/100/12)::bigint END,
  '자동이체',
  CASE WHEN lc.status='연체' THEN 'Y' ELSE 'N' END
FROM loan_contract lc WHERE lc.status IN ('정상','연체');

-- 7) 연체 (NSF 연체전환 기록) ★갭2: 연체 계약 중 작은 5건 전환 누락
CREATE TABLE delinquency (
  delinquency_id    bigserial PRIMARY KEY,
  contract_id       int NOT NULL REFERENCES loan_contract(contract_id),
  start_date        date NOT NULL,
  overdue_days      int NOT NULL,
  overdue_principal bigint NOT NULL,
  overdue_interest  bigint NOT NULL,
  stage             text NOT NULL       -- 1단계|2단계|3단계
);
INSERT INTO delinquency (contract_id, start_date, overdue_days, overdue_principal, overdue_interest, stage)
SELECT lc.contract_id, DATE '2026-06-11',
  (lc.contract_id%80)+1,
  round(lc.principal/lc.term_months)::bigint,
  round(lc.principal*p.delinquent_rate/100/365*((lc.contract_id%80)+1))::bigint,
  CASE WHEN (lc.contract_id%80)+1 >= 60 THEN '3단계'
       WHEN (lc.contract_id%80)+1 >= 30 THEN '2단계' ELSE '1단계' END
FROM loan_contract lc JOIN product p ON p.product_code=lc.product_code
WHERE lc.status='연체'
  AND lc.contract_id NOT IN (
    SELECT contract_id FROM loan_contract WHERE status='연체' ORDER BY contract_id LIMIT 5);

-- 8) 입금 상세=충당 (충당 우선순위) ★갭1: 정상 입금 작은 6건 원금 우선충당
CREATE TABLE deposit_detail (
  detail_id  bigserial PRIMARY KEY,
  deposit_id bigint NOT NULL REFERENCES deposit(deposit_id),
  alloc_type text NOT NULL,             -- 연체이자|이자|원금
  alloc_seq  int  NOT NULL,             -- 충당 순서(작을수록 먼저)
  amount     bigint NOT NULL
);
WITH paid AS (
  SELECT d.deposit_id, d.amount, lc.principal, lc.interest_rate
  FROM deposit d JOIN loan_contract lc ON lc.contract_id=d.contract_id
  WHERE lc.status='정상'
),
gap AS (SELECT deposit_id FROM paid ORDER BY deposit_id LIMIT 6)
INSERT INTO deposit_detail (deposit_id, alloc_type, alloc_seq, amount)
SELECT p.deposit_id, t.alloc_type,
  CASE WHEN g.deposit_id IS NOT NULL THEN t.gap_seq ELSE t.norm_seq END,
  t.amount_val
FROM paid p
LEFT JOIN gap g ON g.deposit_id=p.deposit_id
CROSS JOIN LATERAL (VALUES
   ('연체이자', 1, 3, round(p.amount*0.05)::bigint),
   ('이자',     2, 2, round(p.principal*p.interest_rate/100/12)::bigint),
   ('원금',     3, 1, round(p.amount*0.50)::bigint)
) AS t(alloc_type, norm_seq, gap_seq, amount_val);

-- ---------------------------------------------------------------------
-- 검증 (테이블 건수 + 심어둔 갭 3종 건수)
-- ---------------------------------------------------------------------
SELECT 'customer' AS 항목, count(*) AS 건수 FROM customer
UNION ALL SELECT 'product',            count(*) FROM product
UNION ALL SELECT 'loan_contract',      count(*) FROM loan_contract
UNION ALL SELECT 'repayment_schedule', count(*) FROM repayment_schedule
UNION ALL SELECT 'billing',            count(*) FROM billing
UNION ALL SELECT 'deposit',            count(*) FROM deposit
UNION ALL SELECT 'deposit_detail',     count(*) FROM deposit_detail
UNION ALL SELECT 'delinquency',        count(*) FROM delinquency
UNION ALL SELECT '★갭1 충당순서위반(=6)',
   count(DISTINCT dd1.deposit_id)
   FROM deposit_detail dd1 JOIN deposit_detail dd2 ON dd2.deposit_id=dd1.deposit_id
   WHERE dd1.alloc_type='원금' AND dd2.alloc_type='연체이자'
     AND dd1.alloc_seq < dd2.alloc_seq AND dd2.amount>0
UNION ALL SELECT '★갭2 NSF연체전환누락(=5)',
   count(*) FROM deposit d
   WHERE d.nsf_yn='Y'
     AND NOT EXISTS (SELECT 1 FROM delinquency dl WHERE dl.contract_id=d.contract_id)
UNION ALL SELECT '★갭3 VIP위약금오부과(=4)',
   count(*) FROM billing b
   JOIN loan_contract lc ON lc.contract_id=b.contract_id
   JOIN customer c       ON c.customer_id=lc.customer_id
   WHERE b.bill_type='중도해지위약금' AND c.grade='VIP' AND b.amount>0;

COMMIT;
```

- [ ] **Step 2: VPS에 파일 전송 후 적재 실행**

Run (VPS bash):
```bash
docker exec -i postgres-vector psql -U postgres -d demo_legacy < 01_demo_data.sql
```
Expected: 마지막 검증 결과에 `★갭1 충당순서위반(=6) | 6`, `★갭2 NSF연체전환누락(=5) | 5`, `★갭3 VIP위약금오부과(=4) | 4`, 8개 테이블 건수 출력. 에러 없음.

- [ ] **Step 3: 갭 건수 불일치 시 디버그**

만약 갭 건수가 기대값과 다르면: 갭2는 `status='연체'` 계약 수가 5 미만일 리 없으므로 5 확정. 갭3은 VIP 중도해지 계약이 4건 이상 존재해야 함 — `SELECT count(*) FROM loan_contract lc JOIN customer c ON c.customer_id=lc.customer_id WHERE lc.status='중도해지' AND c.grade='VIP';` 로 4 이상인지 확인. 갭1은 정상계약 입금이 6건 이상인지 확인. 부족하면 `generate_series` 상한(현재 3000)을 늘리지 말고 `LIMIT` 값을 가용 건수로 낮춘다.

---

## Task 2: 회수 규정 5장 작성 + 기존 3장 삭제

**Files:**
- Create: `rules/회수규정_01_청구산정.md`, `회수규정_02_입금충당우선순위.md`, `회수규정_03_연체처리단계.md`, `회수규정_04_NSF처리.md`, `회수규정_05_중도해지환불정산.md`
- Delete: `rules/규칙_01_중도해지_위약금.md`, `규칙_02_자동승인_DTI정책.md`, `규칙_03_연체_처리.md`

**Interfaces:**
- Produces: LightRAG에 적재될 규정 문서. 파일명 접두 `회수규정_`. 갭과 연결: 02→갭1, 04→갭2, 05→갭3.

- [ ] **Step 1: `회수규정_01_청구산정.md` 작성**

```markdown
# 청구 산정 규정

## 적용 대상
모든 여신·할부 계약(신용대출, 담보대출, 오토할부, 리스)의 월별 정기 청구에 적용한다.

## 월 청구액 산정
월 청구액은 해당 회차의 **약정 원금분할액과 약정 이자**의 합으로 산정한다. 원금분할액은 원금을 약정개월(term_months)로 나눈 금액이며, 이자는 잔여 원금에 약정 금리(연이율)를 적용해 월할(연이율/12)로 계산한다.

## 가산 항목
직전 회차 미납이 있는 경우 연체이자를 가산하며, 중도해지 위약금·취급수수료 등 별도 부과 항목이 있으면 청구유형(bill_type)을 구분해 별건으로 청구한다. 정기 청구의 bill_type은 `정기`, 위약금은 `중도해지위약금`으로 기록한다.

## 납기·상태
청구는 매월 생성되며 납기일(due_date)까지 입금되지 않으면 상태를 `미납`으로, 정상 수납되면 `완납`으로 둔다.
```

- [ ] **Step 2: `회수규정_02_입금충당우선순위.md` 작성**

```markdown
# 입금 충당 우선순위 규정

## 원칙 (★ 핵심)
고객의 입금액을 채권에 충당할 때는 반드시 다음 **우선순위 순서**를 따른다.

1. **연체이자** (가장 먼저)
2. **이자**
3. **원금**
4. **수수료**

즉 연체이자 잔액이 남아 있는 한 원금에 먼저 충당해서는 안 된다. 충당 내역(deposit_detail)의 충당순서(alloc_seq)는 이 우선순위를 그대로 반영해야 하며, 숫자가 작을수록 먼저 충당된 것이다.

## 위반 판정
어떤 입금 건의 충당 내역에서 **원금의 충당순서가 연체이자의 충당순서보다 앞서면(작으면)**, 그리고 그 시점 연체이자 충당액이 0보다 크면, 이는 충당 우선순위 규정 위반이다. 시스템이 충당 로직을 잘못 적용했거나 수동 충당이 잘못 입력된 것으로 본다.

## 비고
충당 우선순위는 채권 보전을 위한 회사 정책이며, 고객 등급·상품 유형과 무관하게 동일하게 적용한다.
```

- [ ] **Step 3: `회수규정_03_연체처리단계.md` 작성**

```markdown
# 연체 처리 단계 규정

## 연체 전환
정기 청구의 납기일이 경과하도록 입금이 확인되지 않으면 해당 계약을 연체로 전환하고 연체 기록(delinquency)을 생성한다. 연체 기록에는 연체 시작일, 연체일수, 연체 원금, 연체이자, 단계를 둔다.

## 단계 구분
연체일수(overdue_days)에 따라 단계를 구분한다.
- **1단계**: 연체일수 30일 미만 — 안내·자동이체 재시도 중심.
- **2단계**: 연체일수 30일 이상 60일 미만 — 독촉 및 상담 배정.
- **3단계**: 연체일수 60일 이상 — 채권관리 이관 대상.

## 연체이자 산정
연체이자는 연체 원금에 상품별 연체이자율(product.delinquent_rate)을 적용해 연체일수만큼 일할 계산한다(연체원금 × 연체이자율 ÷ 365 × 연체일수).
```

- [ ] **Step 4: `회수규정_04_NSF처리.md` 작성**

```markdown
# NSF(자동이체 실패) 처리 규정

## NSF 정의
약정 출금일에 자동이체를 시도했으나 고객 계좌의 잔액 부족 등으로 출금이 실패한 건을 NSF(Non-Sufficient Funds)라 한다. 입금 내역(deposit)에서 `nsf_yn='Y'`, 입금액 0으로 기록된다.

## 처리 원칙 (★ 핵심)
NSF가 발생하면 해당 회차는 미납으로 간주하고, **출금 실패일의 익일에 해당 계약을 연체로 전환하여 연체 기록(delinquency)을 생성**해야 한다. 즉 모든 NSF 건은 그에 대응하는 연체 기록이 존재해야 한다.

## 위반 판정
입금 내역에 `nsf_yn='Y'`인 계약인데 **연체 기록(delinquency)이 존재하지 않으면**, 이는 NSF 연체전환 처리가 누락된 것으로 본다. 연체 단계 진행과 연체이자 부과가 시작되지 않아 채권 보전에 공백이 생기므로 즉시 시정 대상이다.

## 재청구
NSF 건은 익월 정기 청구에 미납분과 연체이자를 합산해 재청구한다.
```

- [ ] **Step 5: `회수규정_05_중도해지환불정산.md` 작성** (기존 규칙_01 내용 계승 + 환불 추가)

```markdown
# 중도해지·환불 정산 규정

## 중도해지 위약금
약정 만기 이전에 고객 요청으로 계약이 해지되어 상태가 `중도해지`로 전환되는 건에 위약금을 부과한다. 위약금은 잔여 원금의 2%를 기준으로 하며 단순 산정 시 원금의 2%를 상한으로 본다. 청구는 bill_type `중도해지위약금`으로 기록한다.

## VIP 면제 원칙 (★ 핵심)
고객 등급이 **`VIP`인 경우 중도해지 위약금을 전액 면제한다.** 우량 고객 유지를 위한 회사 정책으로, VIP이면 잔여 원금 규모나 상품 유형과 무관하게 위약금을 부과하지 않는다. 따라서 VIP 고객의 중도해지 건에서 위약금이 0원이 아닌 금액으로 부과되어 있다면 이는 정책 위반이며, 시스템이 면제 처리를 누락한 것으로 본다.

## 일반 고객 / 회사 귀책
등급이 `일반`인 고객은 위 산식대로 정상 부과한다. 회사 귀책 사유(상품 단종, 약관 변경 등)에 의한 해지는 등급과 무관하게 면제한다. 면제 여부는 해지 처리 시점의 고객 등급을 기준으로 판정한다.

## 환불(과오납) 정산
중도해지 정산 결과 또는 과오납으로 고객이 납입한 금액이 채무를 초과하면 그 초과분을 환불한다. 환불은 충당 완료 후 잔액 기준으로 산정하며, 충당 우선순위(연체이자→이자→원금→수수료)를 모두 적용한 뒤의 잉여분에 한한다.
```

- [ ] **Step 6: 기존 규칙 3장 삭제**

Run:
```bash
rm "rules/규칙_01_중도해지_위약금.md" "rules/규칙_02_자동승인_DTI정책.md" "rules/규칙_03_연체_처리.md"
```
Expected: `rules/`에 `회수규정_01~05.md` 5개 + `clean_kb.mjs` + `ingest_rules.mjs`만 남음.

---

## Task 3: KB 청소 + 규정 5장 적재

**Files:**
- Modify: `rules/clean_kb.mjs` (KEEP_PREFIX)
- Run: `rules/ingest_rules.mjs` (변경 없음)

**Interfaces:**
- Consumes: Task 2의 `회수규정_*.md` 5장.
- Produces: LightRAG KB에 회수규정 5장만 적재된 상태.

- [ ] **Step 1: `clean_kb.mjs` 보존 접두 변경**

`rules/clean_kb.mjs:6` 한 줄 교체:
```js
const KEEP_PREFIX = "회수규정_";          // 이 접두 파일만 보존
```
(기존 `"규칙_"` → `"회수규정_"`. 이러면 옛 규칙_·PoC junk 전부 삭제대상이 됨.)

- [ ] **Step 2: KB dry-run으로 삭제 대상 확인**

Run:
```bash
node rules/clean_kb.mjs
```
Expected: `[보존]`이 비어 있고(아직 회수규정 미적재), `[삭제대상]`에 기존 규칙_01~03 + PoC junk 전부 나열.

- [ ] **Step 3: KB 청소 실행**

Run:
```bash
node rules/clean_kb.mjs --yes
```
Expected: `삭제요청: HTTP 200`. 잠시 후 `GET /documents`에 잔존 문서 0 또는 그래프 재생성 진행.

- [ ] **Step 4: 회수규정 5장 적재**

Run:
```bash
node rules/ingest_rules.mjs
```
Expected: `적재할 규칙 5개`, 각 파일 `[200]`. 1~2분 후 인덱싱 완료.

- [ ] **Step 5: 적재 검증 (충당 우선순위 질의)**

Run:
```bash
curl -s -X POST http://193.168.195.222:9621/query \
  -H "Content-Type: application/json" \
  --data-binary '{"query":"입금 충당 우선순위 순서가 뭐야?","mode":"mix","include_references":true}'
```
Expected: 응답에 "연체이자 → 이자 → 원금 → 수수료" 취지 + References에 `회수규정_02_입금충당우선순위.md` 인용.

---

## Task 4: AGENTS.md 시연 시나리오 교체

**Files:**
- Modify: `AGENTS.md` (40~47행 "데모 시나리오" 섹션 + 28~34행 근거블록 예시)

**Interfaces:**
- Consumes: 갭 3종, 회수규정 파일명.

- [ ] **Step 1: `AGENTS.md`의 "## 데모 시나리오 (예)" 섹션(40행~끝)을 아래로 교체**

```markdown
## 데모 시나리오 (킬러 질의 3종)

각 질의는 Postgres(실데이터)와 LightRAG(규정)를 **둘 다** 호출해 대조해야 답이 나온다.

### 1) 충당 순서 위반
> "이번 달 입금 중 충당 순서 규정을 위반한 건 있어?"
→ Postgres `deposit_detail`에서 원금 충당순서가 연체이자보다 앞선 건 조회
→ LightRAG `회수규정_02`에서 충당 우선순위(연체이자→이자→원금→수수료) 조회
→ 대조: **"N건에서 원금이 연체이자보다 먼저 충당됨. 규정 위반 = 갭."**

### 2) NSF 연체전환 누락
> "NSF(자동이체 실패)인데 연체 전환 안 된 계약 찾아줘."
→ Postgres `deposit.nsf_yn='Y'`인데 `delinquency` 행이 없는 계약 조회
→ LightRAG `회수규정_04`에서 "NSF는 익일 연체전환" 규정 조회
→ 대조: **"N건 NSF가 연체전환 누락됨. 규정 위반 = 갭."**

### 3) VIP 위약금 오부과
> "이번 분기 중도해지 중 위약금 정책 위반 있어?"
→ Postgres `billing` 위약금 부과 + 고객등급 VIP + amount>0 조회
→ LightRAG `회수규정_05`에서 "VIP 위약금 전액 면제" 조회
→ 대조: **"VIP N건에 위약금 부과됨. 면제 대상인데 미반영 = 갭."**
```

- [ ] **Step 2: 근거블록 예시(28~34행)의 테이블명을 신규 스키마로 갱신**

`payment` → `billing`로, 예시를 갭3 기준으로 수정:
```
[데이터 · Postgres]
  · 테이블/조건: billing, loan_contract, customer  (bill_type='중도해지위약금' AND grade='VIP' AND amount>0)
  · 해당 행: contract_id ... (총 4건)
[규칙 · LightRAG]
  · 회수규정_05_중도해지환불정산.md — "VIP 고객 위약금 전액 면제"
```

- [ ] **Step 3: 변경 확인**

`AGENTS.md`에 `payment` 잔존 없는지, 회수규정_02/04/05 파일명이 모두 등장하는지 확인.

---

## Task 5: SETUP.md 런북 갱신

**Files:**
- Modify: `SETUP.md` (적재 단계)

- [ ] **Step 1: 데이터 적재 단계를 8테이블 기준으로 갱신**

`SETUP.md`의 데이터 적재 스텝에 다음을 반영:
- 파일명 `data/01_demo_data.sql` (8테이블), VPS 적재 명령 `docker exec -i postgres-vector psql -U postgres -d demo_legacy < 01_demo_data.sql`
- 기대 검증 출력: 갭1=6 / 갭2=5 / 갭3=4
- 규정 적재: `node rules/clean_kb.mjs --yes` → `node rules/ingest_rules.mjs` (회수규정 5장)
- 킬러 질의 3종(Task 4 시나리오) 링크

- [ ] **Step 2: 확인**

`SETUP.md`에 옛 4테이블/규칙_01~03 언급이 남지 않았는지 확인.

---

## Task 6: E2E 킬러 질의 3종 검증

**Files:** (코드 변경 없음 — 실행 검증)

**Interfaces:**
- Consumes: Task 1~5 산출물 전체. OpenCode + MCP(SSH 터널 `-L 15432:localhost:5434` 기동).

- [ ] **Step 1: MCP 재시작 (콘텐츠 변경 반영)**

AGENTS.md/규정 변경은 OpenCode 재시작해야 반영. 터널 기동 후 OpenCode 재기동.

- [ ] **Step 2: 갭1 질의**

OpenCode에 입력: `"이번 달 입금 중 충당 순서 규정을 위반한 건 있어?"`
Expected: 에이전트가 `pg_query`(deposit_detail) + `lightrag_query`(회수규정_02) 호출 → **6건** 위반 지적 + 근거블록 분리 출력.

- [ ] **Step 3: 갭2 질의**

입력: `"NSF인데 연체 전환 안 된 계약 찾아줘."`
Expected: deposit.nsf_yn + delinquency 부재 조회 + 회수규정_04 → **5건** 누락 지적.

- [ ] **Step 4: 갭3 질의**

입력: `"이번 분기 중도해지 중 위약금 정책 위반 있어?"`
Expected: billing 위약금 + VIP 조회 + 회수규정_05 → **4건** 오부과 지적 + 합계 금액.

- [ ] **Step 5: 음성 대조(규칙만/데이터만) 질의로 환각 점검**

입력: `"연체 3단계 기준이 뭐야?"` (규칙만) → 회수규정_03 인용, Postgres 호출 안 함.
입력: `"계약 1번 상환 스케줄 보여줘"` (데이터만) → repayment_schedule 조회, LightRAG 호출 안 함.
Expected: 각 질의가 올바른 단일 툴만 사용, 데이터 없으면 "없음" 정직 응답.

---

## Self-Review (작성자 점검 완료)

- **Spec coverage:** 8테이블(Task1) / 규정5장(Task2) / 갭3종(Task1 데이터+Task2 규정+Task6 시연) / KB청소(Task3) / 시나리오(Task4) / 런북(Task5) — 스펙 §3~6 전부 태스크 매핑됨.
- **Placeholder scan:** 모든 SQL·md·diff 내용 인라인. TBD 없음.
- **Type consistency:** 갭 검증 컬럼 일관(`deposit.nsf_yn`, `deposit_detail.alloc_seq/alloc_type`, `billing.bill_type`). 검증 SELECT의 갭 정의와 AGENTS.md 시나리오 조회 조건 일치.
- **결정적 건수:** 갭1=6(정상입금 LIMIT 6) / 갭2=5(연체 LIMIT 5 제외) / 갭3=4(VIP중도해지 LIMIT 4) — 검증 SELECT가 동일 predicate로 카운트.
```
