---
type: PostgreSQL Table
title: 입금
description: 계약 단위 입금(수납) 한 건당 한 행, NSF 여부를 포함하는 테이블 (2,104건).
resource: postgres://demo_legacy/public/deposit
tags: [입금, 수납, NSF, deposit]
timestamp: '2026-07-14T18:00:00+09:00'
---

수납 원장이다. nsf_yn='Y'(자동이체 출금실패)는 입금이 아니라 **실패 기록**이며
익일 연체전환 대상이다(회수규정_04,
[PKG_COLLECTION](/functions/pkg_collection.md)의 sp_nsf_convert). 정상 입금은
sp_apply_deposit이 규정 순서로 충당해 [deposit_detail](/tables/deposit_detail.md)에
내역을 남긴다.

# Schema

| 컬럼 | 타입 | 설명 (DB 코멘트) |
|------|------|------|
| deposit_id | bigint | PK |
| contract_id | integer | 계약 ID → [loan_contract](/tables/loan_contract.md) |
| paid_date | date | 입금일 (미납 시 NULL) |
| amount | bigint | 입금액 (원) |
| method | text | 수납방법 (자동이체/가상계좌) |
| nsf_yn | character(1) | 자동이체 출금실패(NSF, 잔액부족) 여부 (Y/N) — 회수규정_04 |

# Citations

[1] demo_legacy information_schema (pg_query)
