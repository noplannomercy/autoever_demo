---
type: PL/pgSQL Function Group
title: PKG_COLLECTION 회수/채권관리 패키지
description: 여신 계약의 청구 산정, 연체이자, 중도해지 위약금, 입금 충당, NSF 연체전환을 담당하는 회수 공통 패키지.
resource: postgres://demo_legacy/pkg_collection
tags: [회수, 채권, 충당, 연체, 위약금, NSF, collection]
timestamp: '2026-07-14T18:00:00+09:00'
---

PKG_COLLECTION은 여신/할부 시스템의 회수(채권관리) 공통 패키지다. 2008년
여신시스템 1차 구축 때 만들어져 Oracle 10g에서 4,812줄까지 자란 원본 중
핵심 5개 함수를 PL/pgSQL로 이관한 축약본이며, 원본의 함수명·로직·주석을
보존하고 있다. 2024년 담당자 인수인계 시점 기록이 "명세서 없음, 코드가
명세"인, 전형적인 문서 유실 레거시다.

다섯 함수는 회수 업무의 한 사이클을 이룬다: 매월 청구액을 산정하고
(f_calc_monthly_bill), 입금이 들어오면 규정 순서대로 충당하며
(sp_apply_deposit), 자동이체가 실패하면 연체로 전환하고(sp_nsf_convert),
연체 계약에는 연체이자를 매기며(f_calc_delinq_interest), 계약을 중도해지하면
위약금을 계산한다(f_calc_penalty).

패키지 머리말 주석이 "수정 시 반드시 회수규정집(규정_01~13)과 대조할 것"을
강제한다 — 각 함수의 규정 원천은 아래 의존성 절의 매핑을 따른다.

# 공개 인터페이스

| 이름 | 파라미터 | 반환 | 설명 |
|------|----------|------|------|
| f_calc_monthly_bill | p_contract_id int, p_ym char(6) | bigint | 월 정기 청구액 산정 |
| f_calc_delinq_interest | p_contract_id int, p_asof date | bigint | 기준일 연체이자 산정 |
| f_calc_penalty | p_contract_id int | bigint | 중도해지 위약금 산정 |
| sp_apply_deposit | p_deposit_id bigint | int (충당 행 수) | 입금 충당 처리 |
| sp_nsf_convert | p_deposit_id bigint | int (전환 행 수) | NSF 출금실패 연체전환 |

# 업무 규칙

**월 청구액**(f_calc_monthly_bill)은 당월 상환스케줄의 원금분할액과 이자의
합이다. 완납·중도해지 계약은 청구 대상이 아니어서 0을 반환하고, 존재하지
않는 계약이면 예외를 던진다. 당월 스케줄이 아직 없으면(선청구 등) 약정
산식으로 직접 계산한다: 원금/약정개월 + 원금×금리/100/12, 각각 반올림.
2013년까지 있던 지점별 가산금 로직은 본사 일원화로 제거됐다(주석 보존).

**연체이자**(f_calc_delinq_interest)는 가장 최근 연체 이력 1건을 기준으로
한다. 연체일수는 기록된 값과 "기준일 - 연체시작일 + 1" 중 큰 쪽을 쓰는데,
이는 배치 지연으로 연체일수 갱신이 하루이틀 늦던 2016-09 장애의 재발
방지책이다. 산식은 원금 × 상품별 연체이자율(%) / 100 / 365 × 연체일수이며
원 단위 반올림한다. 분모 365는 윤년에도 고정인데, 이는 2009-04 회계팀
협의로 확정된 계산 관행이다(주석에 "변경 금지" 명시 — 버그가 아니라 합의된
관행). 법정 상한 검사는 이 함수에 없고 상품 등록 단계에서 걸러진다는
전제를 따른다.

**중도해지 위약금**(f_calc_penalty)은 계약 상태가 '중도해지'일 때만
발생한다. VIP 등급 고객은 전액 면제로 0을 반환한다 — 이 면제는 2021-06
전산화 검토 후 보류되어 영업지원팀 수기 정정으로 운영되다가, 2026-07-02에야
전산 반영됐다(함수 이력 주석). 일반 고객 위약금은 원금 × 2%로, 2019-03
약관 개정으로 구 요율 3%에서 내려왔다(구 요율 코드는 주석 보존).

**입금 충당**(sp_apply_deposit)은 회수규정_02의 우선순위를 상수화한
구현으로, **연체이자 → 이자 → 원금 → 수수료** 순서를 따른다(2011-08
충당순서 상수화, "순서 변경 금지" 주석). 연체이자 충당액은
f_calc_delinq_interest의 당일 산정치, 이자 충당액은 당월 약정이자(원금 ×
금리/100/12)를 상한으로 하고, 남은 금액은 전부 원금으로 충당한다. 4순위
수수료는 현행 데이터모델에 수수료 미수 채널이 없어 미구현 블록으로만
존재한다. 충당 내역은 deposit_detail에 alloc_type(한글 코드값:
연체이자/이자/원금)과 alloc_seq(충당 순번)로 남는다. 이미 충당 상세가 있는
입금은 통째로 건너뛰는 재실행 가드가 있다(2014-03 이중충당 장애 재발 방지).
0원 입금(NSF 등)도 충당 대상이 아니다. 참고로 2011-07 규정 개정 전의 구
충당순서는 이자→원금→연체이자였다(주석: "절대 복원 금지").

**NSF 연체전환**(sp_nsf_convert)은 자동이체 출금실패(nsf_yn='Y') 건을 실패일
익일 자로 연체 전환한다. 연체원금은 당월 원금분할액(원금/약정개월), 연체이자는
규정_07 산식의 1일치로 초기화하고, 단계는 연체일수 기준(1~29일 1단계, 30~59일
2단계, 60일 이상 3단계)으로 판정한다 — 다만 전환 시점 연체일수는 항상 1이라
실제로는 1단계로만 생성된다. 해당 계약에 연체 이력이 이미 있으면 전환하지
않는 재실행 가드가 있다.

# 의존성

## 테이블

- 읽기: [loan_contract](/tables/loan_contract.md), [customer](/tables/customer.md),
  [product](/tables/product.md), [repayment_schedule](/tables/repayment_schedule.md),
  [deposit](/tables/deposit.md), [delinquency](/tables/delinquency.md)
- 쓰기: [deposit_detail](/tables/deposit_detail.md) (sp_apply_deposit),
  [delinquency](/tables/delinquency.md) (sp_nsf_convert)

## 규정 원천 매핑 (코드↔규정 대조 시 이 표를 따라 LightRAG를 조회할 것)

| 함수 | 규정 문서 (lightrag_query) | 실데이터 (pg_query) |
|------|---------------------------|---------------------|
| f_calc_monthly_bill | 회수규정_01_청구산정 | repayment_schedule, billing |
| f_calc_delinq_interest | 회수규정_07_연체이자지연배상금 | delinquency, product |
| f_calc_penalty | 회수규정_05_중도해지환불정산 | loan_contract, customer, billing |
| sp_apply_deposit | 회수규정_02_입금충당우선순위 | deposit, deposit_detail |
| sp_nsf_convert | 회수규정_04_NSF처리, 회수규정_03_연체처리단계 | deposit, delinquency |

## 미이관 항목 (원본 Oracle 패키지에만 존재)

독촉장 배치(규정_11), CB 등록(규정_12), 자산건전성 분류(규정_10), 월마감,
중도상환수수료(규정_08). 특히 **중도상환수수료(F_CALC_PREPAY_FEE)는 위약금
(f_calc_penalty)과 별개 개념**이다 — 완납 목적 조기상환에만 적용되므로 혼동
주의(원본 주석 명시).

# Examples

```sql
-- 계약 1234의 2026년 7월 청구액
SELECT pkg_collection.f_calc_monthly_bill(1234, '202607');
```

```sql
-- 입금 98765 충당 처리 (생성된 충당 행 수 반환)
SELECT pkg_collection.sp_apply_deposit(98765);
```

# 주의 지점

- **현재 demo_legacy DB에 함수가 배포되어 있지 않다.** information_schema
  조회 기준 pkg_collection 스키마에 함수 0건 — 소스 파일(legacy_src)로만
  존재한다. 실행 시나리오 전 CREATE OR REPLACE 배포가 선행돼야 한다.
- **연체이자의 원금 기준이 주석과 다르다.** 함수 머리 주석과 회수규정_07은
  "연체원금 × 연체이자율"을 명시하지만, 코드는 delinquency.overdue_principal이
  아니라 **loan_contract.principal(계약 전체 원금)**을 사용한다. 부분 상환이
  진행된 계약일수록 연체이자가 과다 산정된다. 규정_07과 대조 필요.
- **위약금도 계약 전체 원금 기준이다.** f_calc_penalty는 잔여 원금이 아니라
  약정 원금 × 2%를 부과한다. 규정_05의 기준(잔여원금인지 약정원금인지)과
  대조 필요.
- **VIP 면제의 수기 운영 공백 구간이 있다.** 면제가 2021-06 보류(수기 정정
  운영) 후 2026-07-02에야 전산 반영됐으므로, 그 사이 중도해지된 VIP 계약은
  수기 정정 누락 시 위약금이 그대로 부과된 데이터로 남아 있을 수 있다.
- **연체이자는 최근 연체 1건만 본다.** LIMIT 1(최신 start_date)이라 과거
  연체가 여러 건이면 이전 건의 이자는 계산되지 않는다.
- **NSF 재실행 가드가 계약 단위다.** 같은 계약의 두 번째 NSF는 연체 이력
  존재로 스킵된다 — 재연체가 전환되지 않는 경로가 존재한다.
- **충당이 원장을 갱신하지 않는다.** sp_apply_deposit은 deposit_detail만
  생성하고 delinquency나 loan_contract의 잔액·상태는 갱신하지 않는다(축약
  이관 범위일 수 있으나 코드상 사실).

# Citations

[1] [PKG_COLLECTION 소스](../../legacy_src/pkg_collection.sql)
[2] demo_legacy information_schema (테이블 스키마·함수 배포 상태, pg_query 조회)
