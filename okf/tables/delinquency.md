---
type: PostgreSQL Table
title: 연체
description: 계약의 연체 이력(시작일·일수·연체원리금·단계)을 담는 테이블 (229건).
resource: postgres://demo_legacy/public/delinquency
tags: [연체, 단계, delinquency]
timestamp: '2026-07-14T18:00:00+09:00'
---

연체 이력 한 건당 한 행이다. NSF 익일 전환(회수규정_04) 시
[PKG_COLLECTION](/functions/pkg_collection.md)의 sp_nsf_convert가 생성하고,
연체이자 산정(f_calc_delinq_interest)은 이 테이블의 최신 1건을 기준으로
한다. 단계 구분은 회수규정_03(1~29일 1단계 / 30~59일 2단계 / 60일+ 3단계).

주의: overdue_principal(연체 원금) 컬럼이 존재하지만 연체이자 산정 코드는
이를 쓰지 않고 계약 전체 원금을 쓴다 —
[PKG_COLLECTION](/functions/pkg_collection.md) 주의 지점 참조.

# Schema

| 컬럼 | 타입 | 설명 (DB 코멘트) |
|------|------|------|
| delinquency_id | bigint | PK |
| contract_id | integer | 계약 ID → [loan_contract](/tables/loan_contract.md) |
| start_date | date | 연체 시작일 |
| overdue_days | integer | 연체일수 |
| overdue_principal | bigint | 연체 원금 (원) |
| overdue_interest | bigint | 연체이자 (원) — 회수규정_07 |
| stage | text | 연체 단계 (1단계<30일 / 2단계 30~60 / 3단계 60+) — 회수규정_03 |

# Citations

[1] demo_legacy information_schema (pg_query)
