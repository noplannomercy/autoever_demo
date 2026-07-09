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
-- 테이블·컬럼 주석 (dict) — 레거시 데이터 사전 모사. 1막 탐색·에이전트 해석에 사용.
-- ---------------------------------------------------------------------
COMMENT ON TABLE  customer               IS '고객 마스터';
COMMENT ON COLUMN customer.customer_id   IS '고객 ID (PK)';
COMMENT ON COLUMN customer.name          IS '고객명';
COMMENT ON COLUMN customer.grade         IS '고객 등급 (VIP/일반). VIP는 중도해지 위약금 면제 대상';
COMMENT ON COLUMN customer.credit_score  IS '신용점수';
COMMENT ON COLUMN customer.annual_income IS '연소득 (만원)';
COMMENT ON COLUMN customer.dti           IS '총부채원리금상환비율 DTI (%)';

COMMENT ON TABLE  product                 IS '상품 마스터';
COMMENT ON COLUMN product.product_code    IS '상품코드 (PK)';
COMMENT ON COLUMN product.product_name    IS '상품명';
COMMENT ON COLUMN product.product_type    IS '상품유형 (신용대출/담보대출/오토할부/리스)';
COMMENT ON COLUMN product.auto_approve_yn IS '자동승인 여부 (Y/N)';
COMMENT ON COLUMN product.max_dti         IS '자동승인 허용 DTI 상한 (%)';
COMMENT ON COLUMN product.delinquent_rate IS '연체이자율 (%) — 회수규정_07';
COMMENT ON COLUMN product.prepay_fee_rate IS '중도상환수수료율 (%) — 회수규정_08';

COMMENT ON TABLE  loan_contract               IS '여신/할부 계약';
COMMENT ON COLUMN loan_contract.contract_id   IS '계약 ID (PK)';
COMMENT ON COLUMN loan_contract.customer_id   IS '고객 ID (FK→customer)';
COMMENT ON COLUMN loan_contract.product_code  IS '상품코드 (FK→product)';
COMMENT ON COLUMN loan_contract.principal     IS '원금 (원)';
COMMENT ON COLUMN loan_contract.interest_rate IS '약정 금리 (%)';
COMMENT ON COLUMN loan_contract.term_months   IS '약정 개월';
COMMENT ON COLUMN loan_contract.status        IS '계약상태 (정상/완납/중도해지/연체)';
COMMENT ON COLUMN loan_contract.start_date    IS '약정일';

COMMENT ON TABLE  repayment_schedule                IS '월 상환 스케줄 (회차별 분할표)';
COMMENT ON COLUMN repayment_schedule.schedule_id    IS 'PK';
COMMENT ON COLUMN repayment_schedule.contract_id    IS '계약 ID (FK→loan_contract)';
COMMENT ON COLUMN repayment_schedule.installment_no IS '회차';
COMMENT ON COLUMN repayment_schedule.due_date       IS '납기일';
COMMENT ON COLUMN repayment_schedule.principal_due  IS '회차 원금분할액 (원)';
COMMENT ON COLUMN repayment_schedule.interest_due   IS '회차 이자 (원)';
COMMENT ON COLUMN repayment_schedule.total_due      IS '회차 총 상환액 (원)';
COMMENT ON COLUMN repayment_schedule.status         IS '회차 상태 (완납/예정/연체)';

COMMENT ON TABLE  billing             IS '월 청구';
COMMENT ON COLUMN billing.billing_id  IS 'PK';
COMMENT ON COLUMN billing.contract_id IS '계약 ID (FK→loan_contract)';
COMMENT ON COLUMN billing.bill_ym     IS '청구년월 (YYYYMM)';
COMMENT ON COLUMN billing.bill_type   IS '청구유형 (정기/중도해지위약금) — 회수규정_01,05';
COMMENT ON COLUMN billing.amount      IS '청구액 (원)';
COMMENT ON COLUMN billing.due_date    IS '납기일';
COMMENT ON COLUMN billing.status      IS '청구상태 (미납/완납)';

COMMENT ON TABLE  deposit             IS '입금 내역';
COMMENT ON COLUMN deposit.deposit_id  IS 'PK';
COMMENT ON COLUMN deposit.contract_id IS '계약 ID (FK→loan_contract)';
COMMENT ON COLUMN deposit.paid_date   IS '입금일 (미납 시 NULL)';
COMMENT ON COLUMN deposit.amount      IS '입금액 (원)';
COMMENT ON COLUMN deposit.method      IS '수납방법 (자동이체/가상계좌)';
COMMENT ON COLUMN deposit.nsf_yn      IS '자동이체 출금실패(NSF, 잔액부족) 여부 (Y/N) — 회수규정_04';

COMMENT ON TABLE  deposit_detail            IS '입금 상세 (충당 내역)';
COMMENT ON COLUMN deposit_detail.detail_id  IS 'PK';
COMMENT ON COLUMN deposit_detail.deposit_id IS '입금 ID (FK→deposit)';
COMMENT ON COLUMN deposit_detail.alloc_type IS '충당 대상 (연체이자/이자/원금/수수료)';
COMMENT ON COLUMN deposit_detail.alloc_seq  IS '충당 순서 (작을수록 먼저). 규정 순서: 연체이자→이자→원금→수수료 — 회수규정_02';
COMMENT ON COLUMN deposit_detail.amount     IS '충당액 (원)';

COMMENT ON TABLE  delinquency                   IS '연체 기록 (연체전환)';
COMMENT ON COLUMN delinquency.delinquency_id    IS 'PK';
COMMENT ON COLUMN delinquency.contract_id       IS '계약 ID (FK→loan_contract)';
COMMENT ON COLUMN delinquency.start_date        IS '연체 시작일';
COMMENT ON COLUMN delinquency.overdue_days      IS '연체일수';
COMMENT ON COLUMN delinquency.overdue_principal IS '연체 원금 (원)';
COMMENT ON COLUMN delinquency.overdue_interest  IS '연체이자 (원) — 회수규정_07';
COMMENT ON COLUMN delinquency.stage             IS '연체 단계 (1단계<30일 / 2단계 30~60 / 3단계 60+) — 회수규정_03';

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
