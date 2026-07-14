---
type: PostgreSQL Table
title: 고객
description: 고객 한 명당 한 행, 등급·신용정보를 담는 테이블 (2,000건).
resource: postgres://demo_legacy/public/customer
tags: [고객, 등급, VIP, customer]
timestamp: '2026-07-14T18:00:00+09:00'
---

고객 마스터다. 이 도메인에서 가장 중요한 컬럼은 grade — VIP 여부가
중도해지 위약금 전액 면제를 결정한다(회수규정_05,
[PKG_COLLECTION](/functions/pkg_collection.md)의 f_calc_penalty).

# Schema

| 컬럼 | 타입 | 설명 (DB 코멘트) |
|------|------|------|
| customer_id | integer | 고객 ID (PK) |
| name | text | 고객명 |
| grade | text | 고객 등급 (VIP/일반). VIP는 중도해지 위약금 면제 대상 |
| credit_score | integer | 신용점수 |
| annual_income | integer | 연소득 (만원) |
| dti | numeric(5,2) | 총부채원리금상환비율 DTI (%) |

# Citations

[1] demo_legacy information_schema (pg_query)
