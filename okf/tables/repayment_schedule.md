---
type: PostgreSQL Table
title: 상환스케줄
description: 계약의 회차별 상환 예정(원금분할·이자)을 담는 테이블 (12,624건).
resource: postgres://demo_legacy/public/repayment_schedule
tags: [상환, 스케줄, schedule]
timestamp: '2026-07-14T18:00:00+09:00'
---

계약 회차당 한 행이다. 월 청구액 산정(회수규정_01)의 1차 원천 —
[PKG_COLLECTION](/functions/pkg_collection.md)의 f_calc_monthly_bill이 당월
회차의 원금분할액+이자를 합산하고, 당월 회차가 없으면 약정 산식으로
폴백한다.

# Schema

| 컬럼 | 타입 | 설명 (DB 코멘트) |
|------|------|------|
| schedule_id | bigint | PK |
| contract_id | integer | 계약 ID → [loan_contract](/tables/loan_contract.md) |
| installment_no | integer | 회차 |
| due_date | date | 납기일 |
| principal_due | bigint | 회차 원금분할액 (원) |
| interest_due | bigint | 회차 이자 (원) |
| total_due | bigint | 회차 총 상환액 (원) |
| status | text | 회차 상태 (완납/예정/연체) |

# Citations

[1] demo_legacy information_schema (pg_query)
