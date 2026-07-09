# VIP 중도해지 위약금 오부과 근본원인 조사

## 1. 조사 요청

VIP 고객인데 중도해지 위약금이 부과된 계약이 있는지 확인했고, 총 4건이 발견되었다.

이후 요청은 다음과 같았다.

- 데이터 정정은 가능하다.
- 왜 생겼는지 근본 원인을 찾아야 한다.
- 재발 방지를 위해 위약금이 어느 코드에서 어떻게 계산되는지부터 확인해야 한다.

## 2. 정책 확인

LightRAG로 VIP 중도해지 위약금 정책을 확인했다.

결론:

- VIP 고객은 중도해지 위약금 전액 면제 대상이다.
- 잔여 원금 규모나 상품 유형과 관계없이 면제된다.
- VIP 고객의 중도해지 건에 위약금이 0원이 아닌 금액으로 부과되면 정책 위반이다.

근거 문서:

- `회수규정_05_중도해지환불정산.md`
- `역문서_PKG_COLLECTION.md`

## 3. 실제 데이터 확인

조회 조건:

```sql
SELECT c.customer_id,
       c.name,
       c.grade,
       lc.contract_id,
       lc.product_code,
       lc.principal,
       lc.status AS contract_status,
       lc.start_date,
       b.billing_id,
       b.bill_ym,
       b.amount AS penalty_amount,
       b.due_date,
       b.status AS billing_status
FROM billing b
JOIN loan_contract lc ON lc.contract_id = b.contract_id
JOIN customer c ON c.customer_id = lc.customer_id
WHERE c.grade = 'VIP'
  AND lc.status = '중도해지'
  AND b.bill_type = '중도해지위약금'
  AND b.amount > 0
ORDER BY c.customer_id, lc.contract_id;
```

결과:

| 고객ID | 고객명 | 계약ID | 상품 | 계약상태 | 위약금 | 청구월 | 청구상태 |
|---:|---|---:|---|---|---:|---|---|
| 640 | 고객00640 | 203 | P04 | 중도해지 | 660,000원 | 202605 | 완납 |
| 820 | 고객00820 | 63 | P08 | 중도해지 | 1,460,000원 | 202605 | 완납 |
| 1550 | 고객01550 | 273 | P02 | 중도해지 | 260,000원 | 202605 | 완납 |
| 1730 | 고객01730 | 133 | P06 | 중도해지 | 1,060,000원 | 202605 | 완납 |

합계:

- 4건
- 총 3,440,000원

## 4. 관련 코드 위치 탐색

워크스페이스에서 다음 키워드를 검색했다.

- `중도해지위약금`
- `중도해지`
- `위약금`
- `penalty`
- `billing`
- `bill_type`

확인된 주요 파일:

- `data/01_demo_data.sql`
- `legacy_src/pkg_collection.sql`

프로젝트 지침상 레거시 비즈니스 로직의 진실원천은 다음 파일이다.

- `legacy_src/pkg_collection.sql`

## 5. 위약금 계산 함수 확인

위약금 계산 함수는 `pkg_collection.f_calc_penalty(p_contract_id)`이다.

파일 위치:

- `legacy_src/pkg_collection.sql:151-174`

현재 로직:

```sql
CREATE OR REPLACE FUNCTION pkg_collection.f_calc_penalty(
  p_contract_id int
) RETURNS bigint AS $$
DECLARE
  v_principal bigint;
  v_status    text;
BEGIN
  SELECT lc.principal, lc.status
    INTO v_principal, v_status
    FROM loan_contract lc
   WHERE lc.contract_id = p_contract_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PKG_COLLECTION.F_CALC_PENALTY: 계약 없음 (%)', p_contract_id;
  END IF;

  IF v_status <> '중도해지' THEN
    RETURN 0;
  END IF;

  -- 위약금 = 원금 x 2% (2019-03 요율 개정, 구 3%)
  -- ※ 등급별 예외(면제)는 영업지원팀 수기 정정으로 운영 중 (2021-06 김OO)
  --    → 청구 배치는 전 계약 동일 요율 부과, 면제 대상은 사후 수기 0원 처리
  RETURN round(v_principal * 0.02)::bigint;
END;
$$ LANGUAGE plpgsql;
```

확인 사항:

- `loan_contract`만 조회한다.
- `customer` 테이블을 조인하지 않는다.
- `customer.grade = 'VIP'` 조건을 보지 않는다.
- 계약 상태가 `중도해지`이면 고객 등급과 무관하게 `원금 × 2%`를 반환한다.
- 주석상 등급별 면제는 전산 처리되지 않고 영업지원팀 수기 정정으로 운영된다.

## 6. DB에 배포된 함수 확인

DB에 실제 배포된 함수도 확인했다.

조회:

```sql
SELECT n.nspname AS schema,
       p.proname,
       pg_get_functiondef(p.oid) AS definition
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pkg_collection'
  AND p.proname = 'f_calc_penalty';
```

결과:

- DB 함수 정의도 `legacy_src/pkg_collection.sql`과 동일하다.
- VIP 등급 조회 로직이 없다.
- 중도해지면 `round(v_principal * 0.02)::bigint`를 반환한다.

## 7. 실제 오부과 4건과 함수 계산값 비교

검증 쿼리:

```sql
SELECT c.customer_id,
       c.grade,
       lc.contract_id,
       lc.principal,
       b.amount AS billed_penalty,
       pkg_collection.f_calc_penalty(lc.contract_id) AS function_penalty,
       round(lc.principal * 0.02)::bigint AS principal_2pct
FROM billing b
JOIN loan_contract lc ON lc.contract_id = b.contract_id
JOIN customer c ON c.customer_id = lc.customer_id
WHERE b.bill_type = '중도해지위약금'
  AND c.grade = 'VIP'
  AND b.amount > 0
ORDER BY lc.contract_id;
```

결과:

| 계약ID | 고객ID | 등급 | 원금 | 실제 부과액 | 함수 계산값 | 원금 2% |
|---:|---:|---|---:|---:|---:|---:|
| 63 | 820 | VIP | 73,000,000 | 1,460,000 | 1,460,000 | 1,460,000 |
| 133 | 1730 | VIP | 53,000,000 | 1,060,000 | 1,060,000 | 1,060,000 |
| 203 | 640 | VIP | 33,000,000 | 660,000 | 660,000 | 660,000 |
| 273 | 1550 | VIP | 13,000,000 | 260,000 | 260,000 | 260,000 |

결론:

- 오부과 4건은 모두 함수 산식 `원금 × 2%`와 정확히 일치한다.
- 즉 임의 금액이 아니라 현재 위약금 계산 함수의 결과가 그대로 반영된 것이다.

## 8. 데모 데이터 생성 스크립트 확인

데모 데이터 생성 스크립트에도 의도적으로 갭을 심은 로직이 있다.

파일 위치:

- `data/01_demo_data.sql:117-129`

해당 로직:

```sql
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
```

이 스크립트의 동작:

- VIP 중도해지 계약 중 `contract_id` 기준 첫 4건은 `원금 × 2%`를 부과한다.
- 나머지 VIP 중도해지 계약은 0원 처리한다.
- 일반 고객 중도해지 계약은 `원금 × 2%`를 부과한다.

## 9. VIP 중도해지 전체 분포 확인

조회:

```sql
SELECT COUNT(*) AS vip_cancel_total,
       COUNT(*) FILTER (WHERE b.amount > 0) AS vip_penalty_positive,
       COUNT(*) FILTER (WHERE b.amount = 0) AS vip_penalty_zero
FROM loan_contract lc
JOIN customer c ON c.customer_id = lc.customer_id
JOIN billing b ON b.contract_id = lc.contract_id
              AND b.bill_type = '중도해지위약금'
WHERE lc.status = '중도해지'
  AND c.grade = 'VIP';
```

결과:

- VIP 중도해지 전체: 42건
- 위약금 0원 초과: 4건
- 위약금 0원: 38건

## 10. 근본 원인

근본 원인은 두 층으로 나뉜다.

### 10.1 업무 로직의 구조적 원인

`pkg_collection.f_calc_penalty()`가 VIP 면제 정책을 구현하지 않는다.

현재 함수는 다음 조건만 본다.

- 계약 존재 여부
- 계약 상태가 `중도해지`인지 여부
- 원금

보지 않는 조건:

- 고객 등급
- VIP 여부
- 면제 대상 여부

따라서 이 함수만 기준으로 청구를 만들면 VIP 고객도 중도해지 위약금이 계산된다.

### 10.2 운영 프로세스 원인

코드 주석상 2021년에 등급별 면제 전산화가 검토되었으나 보류되었다.

운영 방식은 다음과 같다.

- 청구 배치는 전 계약 동일 요율 부과
- 면제 대상은 사후 수기 0원 처리

이 구조에서는 수기 정정이 누락되면 VIP 위약금 오부과가 재발한다.

### 10.3 데모 데이터의 직접 원인

현재 `demo_legacy` 데이터의 4건은 `data/01_demo_data.sql`에서 의도적으로 만든 갭이다.

스크립트가 VIP 중도해지 첫 4건에만 `원금 × 2%`를 적용하도록 되어 있다.

## 11. 재발 방지 방향

가장 좁고 확실한 재발 방지는 `pkg_collection.f_calc_penalty()` 안에 VIP 면제 조건을 넣는 것이다.

수정 방향:

```sql
CREATE OR REPLACE FUNCTION pkg_collection.f_calc_penalty(
  p_contract_id int
) RETURNS bigint AS $$
DECLARE
  v_principal bigint;
  v_status    text;
  v_grade     text;
BEGIN
  SELECT lc.principal, lc.status, c.grade
    INTO v_principal, v_status, v_grade
    FROM loan_contract lc
    JOIN customer c ON c.customer_id = lc.customer_id
   WHERE lc.contract_id = p_contract_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PKG_COLLECTION.F_CALC_PENALTY: 계약 없음 (%)', p_contract_id;
  END IF;

  IF v_status <> '중도해지' THEN
    RETURN 0;
  END IF;

  IF v_grade = 'VIP' THEN
    RETURN 0;
  END IF;

  RETURN round(v_principal * 0.02)::bigint;
END;
$$ LANGUAGE plpgsql;
```

필요한 후속 조치:

1. `legacy_src/pkg_collection.sql` 수정
2. 사용자 승인 후 DB에 `CREATE OR REPLACE FUNCTION` 배포
3. VIP 중도해지 계약 1건 검증: `f_calc_penalty()`가 0 반환
4. 일반 중도해지 계약 1건 검증: 기존처럼 `원금 × 2%` 반환
5. `data/01_demo_data.sql`의 의도적 갭 주입 로직 제거 또는 별도 시나리오 데이터로 격리
6. 회귀 검증 쿼리 운영화

회귀 검증 쿼리:

```sql
SELECT COUNT(*) AS violation_count
FROM billing b
JOIN loan_contract lc ON lc.contract_id = b.contract_id
JOIN customer c ON c.customer_id = lc.customer_id
WHERE b.bill_type = '중도해지위약금'
  AND c.grade = 'VIP'
  AND b.amount > 0;
```

기대 결과:

```text
violation_count = 0
```

## 12. 최종 결론

VIP 중도해지 위약금 4건은 단순 데이터 오류가 아니다.

정책은 VIP 면제를 요구하지만, 핵심 계산 함수 `f_calc_penalty()`는 고객 등급을 조회하지 않고 중도해지 계약에 `원금 × 2%`를 계산한다.

운영 주석상 이 예외는 전산화되지 않고 수기 정정 대상으로 남아 있었다.

현재 데모 DB의 4건은 `01_demo_data.sql`이 이 구조적 결함을 보여주기 위해 의도적으로 주입한 갭이다.

재발을 막으려면 데이터만 정정하지 말고, `f_calc_penalty()`에 VIP 면제 조건을 구현해야 한다.

## 13. 근거

### 데이터 · Postgres

- 조회 테이블: `billing`, `loan_contract`, `customer`
- 위반 조건: `bill_type='중도해지위약금' AND grade='VIP' AND amount>0`
- 해당 계약: `contract_id` 63, 133, 203, 273
- 총 4건, 총 3,440,000원
- `pkg_collection.f_calc_penalty(contract_id)` 결과가 4건의 청구액과 모두 일치

### 코드 · 로컬 소스

- `legacy_src/pkg_collection.sql:151-174`
  - `f_calc_penalty()`가 중도해지 계약에 `원금 × 2%` 적용
  - VIP 등급 미조회
- `data/01_demo_data.sql:117-129`
  - VIP 중도해지 첫 4건에 `원금 × 2%`를 부과하는 갭 주입 로직

### 규칙 · LightRAG

- `회수규정_05_중도해지환불정산.md`
  - VIP 고객 중도해지 위약금 전액 면제
- `역문서_PKG_COLLECTION.md`
  - `F_CALC_PENALTY`는 원금 2% 기준이며 고객 등급을 조회하지 않음
