# OKF 번들 — 여신 회수 도메인 (autoever_demo)

demo_legacy 레거시(PKG_COLLECTION + 8테이블)를 역문서화한 지식 번들.
OKF(Open Knowledge Format) v0.1 규약을 따른다.

**용도**: 온보딩·분석·수정 작업 시 코드보다 먼저 여기서 업무 맥락을 찾는다.
문서 속 규정 매핑을 따라 LightRAG(`lightrag_query`)로 규정을, 테이블 문서를
따라 Postgres(`pg_query`)로 실데이터를 조회하면 코드↔규정↔데이터 3자
대조가 된다.

- [functions/](functions/index.md) — PKG_COLLECTION 역문서 (업무 규칙·규정 매핑·주의 지점)
- [tables/](tables/index.md) — demo_legacy 8테이블 (스키마·코드값·검증 포인트)

역할 분담: 이 번들 = as-is(코드가 실제로 하는 일) / LightRAG 회수규정 =
should-be(규정) / demo_legacy = evidence(실적). as-is 문서는 LightRAG에
인제스트하지 않는다 — 규정과 의도적으로 모순될 수 있는 문서라 지식 그래프가
오염된다.
