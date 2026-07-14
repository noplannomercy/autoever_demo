---
type: PostgreSQL Table
title: 상품
description: 여신 상품 8종의 유형·승인기준·요율을 담는 코드성 테이블.
resource: postgres://demo_legacy/public/product
tags: [상품, 요율, product]
timestamp: '2026-07-14T18:00:00+09:00'
---

상품 마스터(8건)다. 연체이자율(delinquent_rate)이 연체이자 산정의 요율
원천이고(회수규정_07), 중도상환수수료율(prepay_fee_rate)은 위약금과 별개
개념이니 혼동 주의(회수규정_08,
[PKG_COLLECTION](/functions/pkg_collection.md) 미이관 항목 참조).

# Schema

| 컬럼 | 타입 | 설명 (DB 코멘트) |
|------|------|------|
| product_code | text | 상품코드 (PK) |
| product_name | text | 상품명 |
| product_type | text | 상품유형 (신용대출/담보대출/오토할부/리스) |
| auto_approve_yn | character(1) | 자동승인 여부 (Y/N) |
| max_dti | numeric(5,2) | 자동승인 허용 DTI 상한 (%) |
| delinquent_rate | numeric(4,2) | 연체이자율 (%) — 회수규정_07 |
| prepay_fee_rate | numeric(4,2) | 중도상환수수료율 (%) — 회수규정_08 |

# Citations

[1] demo_legacy information_schema (pg_query)
