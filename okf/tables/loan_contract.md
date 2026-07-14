---
type: PostgreSQL Table
title: 여신계약
description: 여신/할부 계약 한 건당 한 행을 담는 계약 원장 (3,000건).
resource: postgres://demo_legacy/public/loan_contract
tags: [계약, 여신, contract]
timestamp: '2026-07-14T18:00:00+09:00'
---

여신 계약의 원장이다. 원금·금리·기간이 모든 산정(청구, 연체이자, 위약금)의
기준값이 되며, [PKG_COLLECTION](/functions/pkg_collection.md)의 다섯 함수
전부가 이 테이블을 읽는다. 상태 전이는 정상 → 완납/중도해지/연체.

# Schema

| 컬럼 | 타입 | 설명 (DB 코멘트) |
|------|------|------|
| contract_id | integer | 계약 ID (PK) |
| customer_id | integer | 고객 ID → [customer](/tables/customer.md) |
| product_code | text | 상품코드 → [product](/tables/product.md) |
| principal | bigint | 원금 (원) |
| interest_rate | numeric(4,2) | 약정 금리 (%) |
| term_months | integer | 약정 개월 |
| status | text | 계약상태 (정상/완납/중도해지/연체) |
| start_date | date | 약정일 |

# Citations

[1] demo_legacy information_schema (pg_query)
