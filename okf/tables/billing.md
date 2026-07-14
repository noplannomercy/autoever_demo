---
type: PostgreSQL Table
title: 청구
description: 계약의 월별 청구(정기/중도해지위약금)와 납부 상태를 담는 테이블 (2,532건).
resource: postgres://demo_legacy/public/billing
tags: [청구, 위약금, billing]
timestamp: '2026-07-14T18:00:00+09:00'
---

청구 한 건당 한 행이다. bill_type이 '정기'(회수규정_01)와
'중도해지위약금'(회수규정_05)으로 나뉘는 점이 중요하다 — 위약금 부과 실적을
추적할 때 이 테이블의 위약금 유형 행을 고객 등급
([customer](/tables/customer.md).grade)과 대조한다.
[PKG_COLLECTION](/functions/pkg_collection.md)의 산정 함수들이 만들어내는
금액이 여기에 실적으로 남는다.

# Schema

| 컬럼 | 타입 | 설명 (DB 코멘트) |
|------|------|------|
| billing_id | bigint | PK |
| contract_id | integer | 계약 ID → [loan_contract](/tables/loan_contract.md) |
| bill_ym | character(6) | 청구년월 (YYYYMM) |
| bill_type | text | 청구유형 (정기/중도해지위약금) — 회수규정_01,05 |
| amount | bigint | 청구액 (원) |
| due_date | date | 납기일 |
| status | text | 청구상태 (미납/완납) |

# Citations

[1] demo_legacy information_schema (pg_query)
