-- =====================================================================
-- PKG_COLLECTION  (회수/채권관리 공통 패키지)
-- =====================================================================
-- 원본     : GCORE.PKG_COLLECTION (Oracle 10g Package Body, 4,812 lines)
--            ※ 본 파일은 데모용 축약 이관본. 원본 패키지의 핵심 5개
--              프로시저/펑션만 PL/pgSQL로 이관함. 함수명·로직·주석은
--              원본을 최대한 보존.
-- 최초작성 : 2008-11-21 박OO (여신시스템 1차 구축)
-- ---------------------------------------------------------------------
-- 변경이력 :
--   2008-11-21 박OO   최초 작성
--   2009-04-02 박OO   F_CALC_DELINQ_INTEREST 윤년 처리 (365 고정 → 유지,
--                      회계팀 협의: 365 고정 계산 관행 유지 결정)
--   2011-08-17 이OO   SP_APPLY_DEPOSIT 충당순서 상수화 (회수규정 2011-07 개정)
--   2013-02-06 이OO   지점코드 하드코딩 제거 (주석처리로 보존, 하단 참조)
--   2015-10-30 김OO   SP_NSF_CONVERT 신설 (CMS 자동이체 도입, 회수규정_04)
--   2019-03-15 최OO   F_CALC_PENALTY 요율 개정 3% → 2% (약관 개정 반영)
--   2021-06-11 김OO   F_CALC_PENALTY 등급별 면제 검토 → 보류.
--                      영업지원팀 수기 정정으로 운영하기로 함 (전산화 TFT 이월)
--   2024-01-09 정OO   담당자 인수인계 (최OO 퇴사). 명세서 없음, 코드가 명세.
-- ---------------------------------------------------------------------
-- 주의     : 본 패키지 수정 시 반드시 회수규정집(규정_01~13)과 대조할 것.
--            운영 반영은 CREATE OR REPLACE 단위로 수행.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS pkg_collection;

-- =====================================================================
-- F_CALC_MONTHLY_BILL : 월 정기 청구액 산정
-- ---------------------------------------------------------------------
-- 근거     : 회수규정_01 (청구산정) — 월 청구액 = 당월 상환스케줄의
--            원금분할액 + 이자액. 스케줄 미존재 시(예: 스케줄 생성 전
--            선청구) 약정 산식으로 직접 계산한다.
-- 입력     : p_contract_id 계약번호, p_ym 청구년월(YYYYMM)
-- 반환     : 청구액(원). 청구 대상 아님(완납/중도해지)이면 0.
-- 이력     : 2008-11-21 최초. 2010-05 선청구 폴백 추가.
-- =====================================================================
CREATE OR REPLACE FUNCTION pkg_collection.f_calc_monthly_bill(
  p_contract_id int,
  p_ym          char(6)
) RETURNS bigint AS $$
DECLARE
  v_status    text;
  v_principal bigint;
  v_rate      numeric(4,2);
  v_term      int;
  v_amount    bigint;
BEGIN
  SELECT lc.status, lc.principal, lc.interest_rate, lc.term_months
    INTO v_status, v_principal, v_rate, v_term
    FROM loan_contract lc
   WHERE lc.contract_id = p_contract_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PKG_COLLECTION.F_CALC_MONTHLY_BILL: 계약 없음 (%)', p_contract_id;
  END IF;

  -- 완납/중도해지 계약은 정기 청구 대상 아님
  IF v_status IN ('완납', '중도해지') THEN
    RETURN 0;
  END IF;

  -- 1) 당월 상환스케줄 기준 (원금분할 + 이자)  ※ 규정_01 본문 산식
  SELECT sum(rs.principal_due + rs.interest_due)
    INTO v_amount
    FROM repayment_schedule rs
   WHERE rs.contract_id = p_contract_id
     AND to_char(rs.due_date, 'YYYYMM') = p_ym;

  IF v_amount IS NOT NULL THEN
    RETURN v_amount;
  END IF;

  -- 2) 폴백: 스케줄 미생성 구간은 약정 산식으로 직접 산정
  --    (원금/개월수 + 원금*금리/100/12 — 스케줄 생성 로직과 동일해야 함)
  RETURN round(v_principal::numeric / v_term)::bigint
       + round(v_principal * v_rate / 100 / 12)::bigint;

  -- [2013-02-06 이OO] 지점별 가산금 로직 제거 (본사 일원화)
  -- IF v_branch_cd IN ('0021','0034','0107') THEN
  --   v_amount := v_amount + v_branch_surcharge;
  -- END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pkg_collection.f_calc_monthly_bill(int, char) IS
  '월 정기 청구액 산정 (회수규정_01). 당월 스케줄 원금+이자, 폴백은 약정 산식';

-- =====================================================================
-- F_CALC_DELINQ_INTEREST : 연체이자 산정
-- ---------------------------------------------------------------------
-- 근거     : 회수규정_07 (연체이자·지연배상금)
--            연체이자 = 연체원금 × 상품별 연체이자율(%) / 100 / 365 × 연체일수
--            ※ 365 고정(윤년 무시)은 2009-04 회계팀 협의 결정 사항. 변경 금지.
-- 입력     : p_contract_id 계약번호, p_asof 기준일
-- 반환     : 연체이자(원). 연체 기록 없으면 0.
-- =====================================================================
CREATE OR REPLACE FUNCTION pkg_collection.f_calc_delinq_interest(
  p_contract_id int,
  p_asof        date
) RETURNS bigint AS $$
DECLARE
  v_principal bigint;      -- 계약 원금
  v_rate      numeric(4,2); -- 상품 연체이자율(%)
  v_days      int;          -- 연체일수
  v_start     date;
BEGIN
  SELECT dl.start_date, dl.overdue_days
    INTO v_start, v_days
    FROM delinquency dl
   WHERE dl.contract_id = p_contract_id
   ORDER BY dl.start_date DESC
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN 0;   -- 연체 이력 없음
  END IF;

  -- 기준일이 최초 연체전환일보다 뒤면 일수 재계산 (기록값과 큰 쪽 채택)
  -- ※ 배치 지연으로 overdue_days 가 하루이틀 늦게 갱신되는 사례 대응 (2016-09 장애)
  IF p_asof > v_start THEN
    v_days := GREATEST(v_days, (p_asof - v_start) + 1);
  END IF;

  SELECT lc.principal, p.delinquent_rate
    INTO v_principal, v_rate
    FROM loan_contract lc
    JOIN product p ON p.product_code = lc.product_code
   WHERE lc.contract_id = p_contract_id;

  -- 법정 상한 체크는 상품 등록 단계에서 걸러짐 (규정_07 §3) — 여기서는 미검사
  RETURN round(v_principal * v_rate / 100 / 365 * v_days)::bigint;

  -- [2009-04-02 박OO] 윤년 분기 (회계팀 협의로 폐기 — 365 고정)
  -- v_base_days := CASE WHEN is_leap_year(p_asof) THEN 366 ELSE 365 END;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pkg_collection.f_calc_delinq_interest(int, date) IS
  '연체이자 산정 (회수규정_07). 연체원금×연체이자율/100/365×연체일수, 365 고정';

-- =====================================================================
-- F_CALC_PENALTY : 중도해지 위약금 산정
-- ---------------------------------------------------------------------
-- 근거     : 회수규정_05 (중도해지 환불정산) — 위약금 조항
-- 입력     : p_contract_id 계약번호
-- 반환     : 위약금(원). 중도해지 계약이 아니거나 VIP 고객이면 0.
-- 이력     : 2019-03-15 요율 개정 3% → 2%
--            2021-06-11 등급별 면제 전산화 검토 → 보류 (하단 주석 참조)
--            2026-07-02 회수규정_05 VIP 전액 면제 전산 반영
-- =====================================================================
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

  -- 회수규정_05: VIP 고객은 잔여 원금/상품 유형과 무관하게 전액 면제
  IF v_grade = 'VIP' THEN
    RETURN 0;
  END IF;

  -- 위약금 = 원금 x 2% (2019-03 요율 개정, 구 3%)
  RETURN round(v_principal * 0.02)::bigint;

  -- [2019-03-15 최OO] 구 요율 보존
  -- RETURN round(v_principal * 0.03)::bigint;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pkg_collection.f_calc_penalty(int) IS
  '중도해지 위약금 산정 (회수규정_05). VIP는 전액 면제, 일반은 원금×2%';

-- =====================================================================
-- SP_APPLY_DEPOSIT : 입금 충당 처리
-- ---------------------------------------------------------------------
-- 근거     : 회수규정_02 (입금충당 우선순위)
--            충당 순서: 연체이자 → 이자 → 원금 → 수수료  ※ 순서 변경 금지
-- 입력     : p_deposit_id 입금번호
-- 반환     : 생성된 충당(deposit_detail) 행 수. 이미 충당됐거나 입금액 0이면 0.
-- 이력     : 2011-08-17 충당순서 상수화 (규정 2011-07 개정 반영)
-- 주의     : 재실행 안전 — 기충당 입금은 건드리지 않는다 (2014-03 이중충당 장애 재발방지)
-- =====================================================================
CREATE OR REPLACE FUNCTION pkg_collection.sp_apply_deposit(
  p_deposit_id bigint
) RETURNS int AS $$
DECLARE
  v_contract_id int;
  v_amount      bigint;      -- 입금액(미충당 잔액)
  v_due         bigint;
  v_alloc       bigint;
  v_seq         int := 0;
  v_rows        int := 0;
  v_monthly_int bigint;      -- 당월 약정이자
BEGIN
  SELECT d.contract_id, d.amount
    INTO v_contract_id, v_amount
    FROM deposit d
   WHERE d.deposit_id = p_deposit_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PKG_COLLECTION.SP_APPLY_DEPOSIT: 입금 없음 (%)', p_deposit_id;
  END IF;

  -- 재실행 가드: 이미 충당 상세가 있으면 스킵 (이중충당 방지, 2014-03)
  IF EXISTS (SELECT 1 FROM deposit_detail dd WHERE dd.deposit_id = p_deposit_id) THEN
    RETURN 0;
  END IF;

  IF v_amount <= 0 THEN
    RETURN 0;   -- NSF 등 0원 입금은 충당 대상 아님 (SP_NSF_CONVERT 담당)
  END IF;

  -- ── 1순위: 연체이자 ────────────────────────────── 규정_02 §2 (1)
  v_due := pkg_collection.f_calc_delinq_interest(v_contract_id, CURRENT_DATE);
  IF v_due > 0 THEN
    v_alloc := LEAST(v_amount, v_due);
    v_seq   := v_seq + 1;
    INSERT INTO deposit_detail (deposit_id, alloc_type, alloc_seq, amount)
    VALUES (p_deposit_id, '연체이자', v_seq, v_alloc);
    v_amount := v_amount - v_alloc;
    v_rows   := v_rows + 1;
  END IF;

  -- ── 2순위: 이자 (당월 약정이자) ────────────────── 규정_02 §2 (2)
  IF v_amount > 0 THEN
    SELECT round(lc.principal * lc.interest_rate / 100 / 12)::bigint
      INTO v_monthly_int
      FROM loan_contract lc
     WHERE lc.contract_id = v_contract_id;
    v_alloc := LEAST(v_amount, COALESCE(v_monthly_int, 0));
    IF v_alloc > 0 THEN
      v_seq := v_seq + 1;
      INSERT INTO deposit_detail (deposit_id, alloc_type, alloc_seq, amount)
      VALUES (p_deposit_id, '이자', v_seq, v_alloc);
      v_amount := v_amount - v_alloc;
      v_rows   := v_rows + 1;
    END IF;
  END IF;

  -- ── 3순위: 원금 ────────────────────────────────── 규정_02 §2 (3)
  IF v_amount > 0 THEN
    v_seq := v_seq + 1;
    INSERT INTO deposit_detail (deposit_id, alloc_type, alloc_seq, amount)
    VALUES (p_deposit_id, '원금', v_seq, v_amount);
    v_amount := 0;
    v_rows   := v_rows + 1;
  END IF;

  -- ── 4순위: 수수료 ──────────────────────────────── 규정_02 §2 (4)
  -- 현행 데이터모델에 수수료 미수 채널 없음 — 원금 충당 후 잔액은 발생하지 않는다.
  -- (수수료 채권 신설 시 이 블록을 활성화할 것: alloc_type='수수료')

  RETURN v_rows;

  -- [2011-08-17 이OO] 구 충당순서 (2011-07 규정 개정 전: 이자→원금→연체이자)
  -- 개정 전 코드는 형상관리 rev.1847 참조. 절대 복원 금지.
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pkg_collection.sp_apply_deposit(bigint) IS
  '입금 충당 처리 (회수규정_02). 연체이자→이자→원금→수수료. 기충당 건 재실행 안전';

-- =====================================================================
-- SP_NSF_CONVERT : NSF(자동이체 출금실패) 연체전환
-- ---------------------------------------------------------------------
-- 근거     : 회수규정_04 (NSF 처리) — 출금 실패 회차는 미납 처리하고
--            실패일 익일 자로 연체전환(delinquency 생성)한다.
--            단계 산정은 회수규정_03 (1~29일=1단계, 30~59일=2단계, 60일+=3단계)
-- 입력     : p_deposit_id 입금번호 (nsf_yn='Y' 건)
-- 반환     : 생성된 연체 행 수 (0=대상 아님 또는 기전환)
-- 이력     : 2015-10-30 신설 (CMS 자동이체 도입)
-- =====================================================================
CREATE OR REPLACE FUNCTION pkg_collection.sp_nsf_convert(
  p_deposit_id bigint
) RETURNS int AS $$
DECLARE
  v_contract_id int;
  v_nsf         char(1);
  v_start       date;
  v_days        int;
  v_principal   bigint;
  v_term        int;
  v_rate        numeric(4,2);
BEGIN
  SELECT d.contract_id, d.nsf_yn, COALESCE(d.paid_date, CURRENT_DATE)
    INTO v_contract_id, v_nsf, v_start
    FROM deposit d
   WHERE d.deposit_id = p_deposit_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PKG_COLLECTION.SP_NSF_CONVERT: 입금 없음 (%)', p_deposit_id;
  END IF;

  IF v_nsf <> 'Y' THEN
    RETURN 0;   -- 정상 출금 건은 대상 아님
  END IF;

  -- 재실행 가드: 이미 연체전환된 계약은 스킵
  IF EXISTS (SELECT 1 FROM delinquency dl WHERE dl.contract_id = v_contract_id) THEN
    RETURN 0;
  END IF;

  SELECT lc.principal, lc.term_months, p.delinquent_rate
    INTO v_principal, v_term, v_rate
    FROM loan_contract lc
    JOIN product p ON p.product_code = lc.product_code
   WHERE lc.contract_id = v_contract_id;

  -- 익일 연체전환 (규정_04 §1) — 전환 시점 연체일수 1일
  v_start := v_start + 1;
  v_days  := 1;

  INSERT INTO delinquency
    (contract_id, start_date, overdue_days, overdue_principal, overdue_interest, stage)
  VALUES
    (v_contract_id,
     v_start,
     v_days,
     round(v_principal::numeric / v_term)::bigint,             -- 연체원금 = 당월 원금분할액
     round(v_principal * v_rate / 100 / 365 * v_days)::bigint, -- 연체이자 (규정_07 산식)
     CASE WHEN v_days >= 60 THEN '3단계'
          WHEN v_days >= 30 THEN '2단계'
          ELSE '1단계' END);                                    -- 규정_03 단계 기준

  RETURN 1;

  -- [2015-10-30 김OO] 도입 초기 재출금(재시도) 로직 — CMS센터 이관으로 폐기
  -- PERFORM pkg_collection.sp_retry_withdraw(p_deposit_id, 2);  -- 2영업일 후 재출금
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pkg_collection.sp_nsf_convert(bigint) IS
  'NSF 익일 연체전환 (회수규정_04). 기전환 계약 재실행 안전. 단계는 규정_03 기준';

-- =====================================================================
-- (참고) 원본 Oracle 패키지에서 이관하지 않은 항목
-- ---------------------------------------------------------------------
--   SP_DUNNING_BATCH      : 독촉장 발송 배치 (규정_11) — 대외계 연동이라 제외
--   SP_CB_REPORT          : 연체정보 CB 등록 (규정_12) — 대외계 연동이라 제외
--   F_ASSET_CLASS         : 자산건전성 분류 (규정_10) — 결산계 소관
--   SP_MONTHLY_CLOSE      : 월마감 — 스케줄러 소관
--   F_CALC_PREPAY_FEE     : 중도상환수수료 (규정_08) — 위약금(F_CALC_PENALTY)과
--                           별개 개념이므로 혼동 주의. 완납 목적 조기상환에만 적용.
-- =====================================================================
-- END OF PACKAGE
-- =====================================================================
