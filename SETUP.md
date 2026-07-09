# 오토에버 데모 — 콘텐츠 운영 런북 (운영자/빌더용)

> 이 문서는 **콘텐츠(데이터·규정) 적재·갱신·리셋 + 트러블슈팅** 전용이다.
> **연결·실행(OpenCode 전역설정)은 → `docs/00_사용자환경구성.md`**, 최초 서버 배포는 → `docs/05_운영배포.md`.
> 연결은 OpenCode 전역설정의 remote MCP로 한다 — **폴더에서 opencode를 켤 필요 없음.** SSH 터널·로컬 node도 불필요.
> **폐쇄망(오토에버 VDI) 시연은 → `docs/09_폐쇄망_시연구성_LibreChat.md`** — 브라우저로 `https://srv1768237.hstgr.cloud/` 접속만 하면 됨 (클라이언트 설치 불필요).

## 0. 구조 한 장

```
[로컬 OpenCode] ──HTTPS + Bearer──▶ [VPS Caddy :443]
                                      ├─ /postgres/* → 127.0.0.1:8011 → demo_legacy(:5434)
                                      └─ /lightrag/* → 127.0.0.1:8012 → LightRAG(:9621)
```

상세 구조는 `docs/01_아키텍처.md`.

## 1. 전제

- **VPS(`72.62.242.236`)** 에 두 MCP 서버 + Caddy가 systemd로 가동 중이어야 한다. (배포 안 돼 있으면 `docs/05_운영배포.md`)
- **운영자가 콘텐츠를 만지려면** 이 폴더(`data/`·`rules/` + VPS SSH 접근)가 필요하다.
- **연결·실행**은 전역설정으로 → `docs/00`. 환경 상수/토큰: `docs/01_아키텍처.md §8`.

---

## 2. 서버 생존 확인 (작업 전)

MCP 게이트웨이가 살아있는지 외부에서 확인:
```bash
TOK="<MCP_TOKEN>"
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://72-62-242-236.sslip.io/postgres/mcp \
  -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
# → 200 이면 DNS+TLS+Caddy+인증+서버 OK.  /lightrag/mcp 도 동일 확인.
```
> OpenCode 연결·툴 확인은 → `docs/00_사용자환경구성.md §2`.

---

## 3. 콘텐츠 적재 / 갱신

> 이미 적재돼 있음(데이터 8테이블 + 규정 13장). **새로 깔거나 갱신할 때만** 아래 수행.

### 3-1. Postgres 데이터 → `data/01_demo_data.sql`
노트북에 psql이 없으므로 VPS에서 docker로 직결 적재:
```bash
scp data/01_demo_data.sql root@72.62.242.236:/root/
ssh root@72.62.242.236 'docker exec -i postgres-vector psql -U postgres -d demo_legacy < /root/01_demo_data.sql'
```
끝의 검증표에서 **갭 3종이 정확히** 떨어지면 정상: `★갭1=6 · ★갭2=5 · ★갭3=4`.
(상세: `docs/02_데이터모델.md`)

### 3-2. LightRAG 규정 → `rules/회수규정_*.md` (13장)
> ⚠️ 9621은 방화벽으로 외부 차단됨(2026-07-09 보안 조치) — **서버 위에서** 실행해야 한다. rules/는 서버 `/opt/autoever_demo/rules`에 있음 (갱신 시 scp로 동기화 후 실행).
```bash
ssh root@72.62.242.236
cd /opt/autoever_demo/rules
node clean_kb.mjs          # dry-run: KB 현황 확인(회수규정_ 보존 / 그 외 삭제대상)
node clean_kb.mjs --yes    # (오염분 있을 때만) 청소
node ingest_rules.mjs      # 13장 적재. 기존분은 409 스킵, 신규만 200
```
적재 검증 (서버에서):
```bash
curl -s -X POST http://127.0.0.1:9621/query -H "Content-Type: application/json" \
  --data-binary '{"query":"입금 충당 우선순위 순서가 뭐야?","mode":"mix","include_references":true}'
# → "연체이자→이자→원금→수수료" + 회수규정_02 인용
```
(상세: `docs/03_지식베이스.md`)

---

## 4. 데모 실행

OpenCode에서 **킬러 질의 3종**(기대 6 / 5 / 4건) 던지기. 질의문·기대답·근거블록·세일즈 포인트는 → **`docs/04_시연가이드.md`**.

빠른 확인용 3종:
```
이번 달 입금 중 충당 순서 규정을 위반한 건 있어?        (6건)
NSF인데 연체 전환 안 된 계약 찾아줘.                     (5건)
이번 분기 중도해지 중 위약금 정책 위반 있어?            (4건, ₩3,440,000)
```

---

## 5. 트러블슈팅 (remote)

| 증상 | 조치 |
|------|------|
| OpenCode에 툴 안 뜸 | §2 서버 200 확인 / OpenCode 설정(전역 또는 프로젝트)의 Bearer ↔ VPS env `MCP_TOKEN` 일치 |
| 401 unauthorized | 토큰 불일치 — OpenCode 설정의 Bearer ↔ VPS `*.env` 비교 |
| 502 (Caddy) | node 서비스 죽음 → VPS `systemctl status postgres-mcp lightrag-mcp` |
| postgres 연결거부 | VPS 컨테이너 5434 / `demo_legacy` 존재 확인 |
| lightrag 빈 응답·404 | LightRAG `:9621` 생존 / 인덱싱 완료(`GET /documents`) 확인 |

운영 명령(재시작·로그·토큰 교체)·최초 배포는 → **`docs/05_운영배포.md`**.
