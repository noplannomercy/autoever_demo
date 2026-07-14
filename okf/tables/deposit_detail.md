---
type: PostgreSQL Table
title: 입금충당상세
description: 입금 한 건이 연체이자·이자·원금에 어떻게 배분됐는지 순번과 함께 기록하는 테이블 (5,610건).
resource: postgres://demo_legacy/public/deposit_detail
tags: [충당, 입금, 우선순위, deposit]
timestamp: '2026-07-14T18:00:00+09:00'
---

충당 배분 한 건당 한 행이다. **충당 순서 규정(회수규정_02: 연체이자 → 이자 →
원금 → 수수료) 준수 여부를 검증할 수 있는 유일한 증거 테이블** — alloc_seq가
작을수록 먼저 충당된 것이므로, 원금이 연체이자보다 앞선 행 조합은 규정
위반이다. 쓰기는 [PKG_COLLECTION](/functions/pkg_collection.md)의
sp_apply_deposit이 전담한다.

# Schema

| 컬럼 | 타입 | 설명 (DB 코멘트) |
|------|------|------|
| detail_id | bigint | PK |
| deposit_id | bigint | 입금 ID → [deposit](/tables/deposit.md) |
| alloc_type | text | 충당 대상 (연체이자/이자/원금/수수료) |
| alloc_seq | integer | 충당 순서 (작을수록 먼저). 규정 순서: 연체이자→이자→원금→수수료 — 회수규정_02 |
| amount | bigint | 충당액 (원) |

# Citations

[1] demo_legacy information_schema (pg_query)
