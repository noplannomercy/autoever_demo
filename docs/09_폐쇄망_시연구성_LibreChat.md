# 09. 폐쇄망 시연 구성 — LibreChat (브라우저 온리)

> ⚠️ **2026-07-20: 이 문서의 서버(srv1768237)는 만료·폐기됨.** 현행 시연 URL은 **`https://srv1842066.hstgr.cloud/`** (계정 동일) — 재배포 기록은 `10_재배포_2026-07-20_srv1842066.md` 참조. 아래 절차·트러블슈팅은 그대로 유효 (2026-07-20 재배포에서 재검증됨).

> 작성: 2026-07-09 · 상태: **배포·E2E 테스트 완료** · 배경: 오토에버 폐쇄망 VDI에서 클라이언트(OpenCode) 설치 불가 → 에이전트를 서버로 올리고 VDI는 브라우저만 사용
> 관련: 배포 테스트 `08_외부배포_테스트결과.md` · 시연가이드 `04_시연가이드.md`

## 0. 결과 요약

**VDI에서 브라우저 하나로 전체 데모 가능.** LibreChat(네이티브 MCP 클라이언트)을 VPS에 배포, 킬러 질의 2종 E2E 통과:

| 질의 | 기대값 | 실제 결과 |
|------|--------|----------|
| 입금 충당 순서 규정 위반 | 6건 | ✅ **6건** + 회수규정_02 인용 + 위반 상세표 (9회 툴 호출) |
| 중도해지 위약금 정책 위반 | 4건, ₩3,440,000 | ✅ **4건, 3,440,000원** + 회수규정_05 인용 + VIP 면제규정 설명 (26회 툴 호출) |

에이전트가 `pg_query`(사실)·`lightrag_query`(의미)를 스스로 골라 교차검증하는 과정이 **툴 호출 로그로 화면에 그대로 노출** — "모델의 MCP 통제"가 시연 포인트 그 자체로 보인다.

## 1. 시연 접속 정보

| 항목 | 값 |
|------|-----|
| 시연 URL (VDI 브라우저) | **`https://srv1768237.hstgr.cloud/`** |
| 계정 | `demo@autoever-demo.com` / `<DEMO_PASSWORD>` |
| 모델 | OpenRouter → `anthropic/claude-sonnet-4.5` |
| MCP | 입력창 아래 "MCP Servers" 드롭다운 → **postgres + lightrag 둘 다 체크** |

> ⚠️ sslip.io 주소는 오토에버 망에서 **유해사이트 차단**에 걸림(확인됨). 반드시 `srv1768237.hstgr.cloud` 사용. 이 도메인은 VDI에서 통과 확인됨(2026-07-09).

## 2. 시연 순서 (VDI에서)

1. 브라우저 → `https://srv1768237.hstgr.cloud/` → 로그인
2. 좌상단 모델 선택 → OpenRouter → `claude-sonnet-4.5` 검색·선택
3. 입력창 아래 MCP Servers 드롭다운 → postgres·lightrag 체크 ("2 selected")
4. 킬러 질의 3종 (`04_시연가이드.md`) 순서대로:
   - 이번 달 입금 중 충당 순서 규정을 위반한 건 있어? (→ 6건)
   - NSF인데 연체 전환 안 된 계약 찾아줘. (→ 5건)
   - 이번 분기 중도해지 중 위약금 정책 위반 있어? (→ 4건, ₩3,440,000)
5. **연출 포인트**: 답변 위 "Used N tools — postgres, lightrag" 펼쳐서 에이전트가 규정(KB)과 데이터(DB)를 오가며 검증한 과정을 보여줄 것

## 3. 아키텍처

```
[VDI 브라우저] ──HTTPS 443──▶ [VPS Caddy]  srv1768237.hstgr.cloud (Let's Encrypt)
                                ├─ /            → LibreChat :3080 (docker, 127.0.0.1 바인딩)
                                │                  ├─ 모델: OpenRouter (claude-sonnet-4.5)
                                │                  ├─ MCP: postgres/lightrag (게이트웨이 경유)
                                │                  └─ MongoDB (대화 저장)
                                ├─ /postgres/*  → postgres-mcp :8011 → demo_legacy
                                └─ /lightrag/*  → lightrag-mcp :8012 → LightRAG :9621
```

- LibreChat 선택 이유: **네이티브 MCP 클라이언트**(streamable HTTP + Bearer 헤더 = 기존 게이트웨이 그대로), 툴 호출 인라인 가시화. OWU는 mcpo 변환 계층 필요 + 툴 가시성 낮음.
- 기존 OpenCode 경로(로컬 전역설정)는 그대로 병행 동작.

## 4. 설치 절차 (실행한 명령 전체 — 재현용)

전제: `08_외부배포_테스트결과.md`의 스택(MCP 2종 + Caddy + LightRAG + demo_legacy)이 이미 가동 중인 VPS. 아래는 그 위에 LibreChat만 얹는 절차다.

### 4-1. 도메인 준비 (sslip.io 차단 대응)

Hostinger VPS 기본 호스트네임(`srvXXXXXXX.hstgr.cloud`)은 DNS에 이미 등록돼 있다 (`nslookup`으로 확인). Caddy vhost에 추가만 하면 인증서 자동 발급:
```bash
sed -i 's/^72-62-242-236.sslip.io {/72-62-242-236.sslip.io, srv1768237.hstgr.cloud {/' /etc/caddy/Caddyfile
systemctl reload caddy
# journalctl -u caddy | grep "certificate obtained" 로 발급 확인
```

### 4-2. LibreChat 클론 + 설정 3종

```bash
apt-get install -y docker-compose-v2          # docker.io엔 compose 플러그인 없음
cd /opt && git clone https://github.com/danny-avila/LibreChat.git librechat
cd librechat && cp .env.example .env
```

**`.env` 수정** (시크릿은 신규 생성, 키는 기존 자산 재사용):
```bash
JWT1=$(openssl rand -hex 32); JWT2=$(openssl rand -hex 32)
CK=$(openssl rand -hex 32);  CIV=$(openssl rand -hex 16)
MCPTOK=$(grep MCP_TOKEN /opt/autoever_demo/postgres-mcp.env | cut -d= -f2)
sed -i "s|^HOST=.*|HOST=0.0.0.0|; \
  s|^DOMAIN_CLIENT=.*|DOMAIN_CLIENT=https://srv1768237.hstgr.cloud|; \
  s|^DOMAIN_SERVER=.*|DOMAIN_SERVER=https://srv1768237.hstgr.cloud|; \
  s|^JWT_SECRET=.*|JWT_SECRET=$JWT1|; s|^JWT_REFRESH_SECRET=.*|JWT_REFRESH_SECRET=$JWT2|; \
  s|^CREDS_KEY=.*|CREDS_KEY=$CK|; s|^CREDS_IV=.*|CREDS_IV=$CIV|; \
  s|^SEARCH=.*|SEARCH=false|; s|^ALLOW_REGISTRATION=.*|ALLOW_REGISTRATION=true|" .env
echo "OPENROUTER_KEY=<OpenRouter 키>" >> .env      # 변수명 주의: OPENROUTER_API_KEY 쓰면 안 됨(OpenAI 엔드포인트 오염)
chmod 600 .env
```

**`librechat.yaml` 생성** (원문 그대로 — 트러블슈팅 #3·#5·#6이 반영된 형태):
```yaml
version: 1.3.13
cache: true
endpoints:
  custom:
    - name: 'OpenRouter'
      apiKey: '${OPENROUTER_KEY}'
      baseURL: 'https://openrouter.ai/api/v1'
      models:
        default: ['anthropic/claude-sonnet-4.5', 'anthropic/claude-3.5-sonnet']
        fetch: true
      titleConvo: true
      titleModel: 'openai/gpt-4o-mini'
      dropParams: ['stop']
      modelDisplayLabel: 'OpenRouter'
mcpSettings:
  allowedDomains:
    - 'srv1768237.hstgr.cloud'          # 없으면 SSRF 보호에 걸려 "Domain not allowed"
mcpServers:
  postgres:
    type: streamable-http
    requiresOAuth: false                 # 없으면 401 프로브 → OAuth 오판 → 툴 0개
    url: https://srv1768237.hstgr.cloud/postgres/mcp
    headers:
      Authorization: 'Bearer <MCP_TOKEN 실제값>'   # ${MCP_TOKEN} 치환 미동작(v0.8.7) → 직접 기입 + chmod 600
    timeout: 60000
    initTimeout: 15000
  lightrag:
    type: streamable-http
    requiresOAuth: false
    url: https://srv1768237.hstgr.cloud/lightrag/mcp
    headers:
      Authorization: 'Bearer <MCP_TOKEN 실제값>'
    timeout: 150000
    initTimeout: 15000
```
```bash
chmod 600 librechat.yaml
```

**`docker-compose.override.yml` 생성** (원문 그대로):
```yaml
services:
  api:
    ports: !override
      - "127.0.0.1:3080:3080"            # 직접 외부노출 차단 — 진입은 Caddy만
    volumes:
      - type: bind
        source: ./librechat.yaml
        target: /app/librechat.yaml      # 기본 compose엔 이 마운트가 없음(트러블슈팅 #2)
    extra_hosts:
      - "srv1768237.hstgr.cloud:host-gateway"   # 호스트 /etc/hosts의 127.0.1.1 상속 문제 해소(#4)
```

### 4-3. Caddy 루트 경로 → LibreChat

`/etc/caddy/Caddyfile`의 catch-all `handle` 블록을 `respond` 대신 프록시로:
```
	handle {
		reverse_proxy 127.0.0.1:3080
	}
```
```bash
caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy
```

### 4-4. 기동 + 검증

```bash
cd /opt/librechat && docker compose up -d api mongodb   # rag_api·vectordb가 의존성으로 같이 뜸(무해)
sleep 25 && docker logs LibreChat 2>&1 | grep -E "\[MCP\].*(Tools|Initialized with)"
# 기대: Tools: pg_query, pg_execute / Tools: lightrag_query / "2 configured servers and 3 tools"
curl -s https://srv1768237.hstgr.cloud/ | grep -o "<title>[^<]*</title>"   # <title>LibreChat</title>
```

### 4-5. 데모 계정 생성 (API로 1회)

```bash
curl -X POST https://srv1768237.hstgr.cloud/api/auth/register -H "Content-Type: application/json" \
  -d '{"name":"Autoever Demo","email":"demo@autoever-demo.com","username":"autoever","password":"<DEMO_PASSWORD>","confirm_password":"<DEMO_PASSWORD>"}'
```

## 4+. 실행법 (사용자 관점 — VDI/일반 브라우저 공통)

1. `https://srv1768237.hstgr.cloud/` 접속 → 로그인 (§1 계정)
2. 좌상단 모델명 클릭 → 검색창에 `claude-sonnet-4.5` → **OpenRouter › anthropic/claude-sonnet-4.5** 선택
3. 입력창 아래 **"MCP Servers"** 드롭다운 → `postgres`·`lightrag` 체크 → "2 selected" 표시 확인
4. 질의 입력 → 전송. 답변 상단 "Used N tools" 클릭하면 툴 호출 내역(어떤 SQL을 왜 실행했는지) 펼쳐짐
5. 모델·MCP 선택은 브라우저에 유지됨 — 새 대화를 열어도 재설정 불필요 (단, 다른 PC/브라우저에선 2~3 다시 수행)

## 5. 트러블슈팅 기록 (재발 시 참조)

| # | 증상 | 원인 | 해결 |
|---|------|------|------|
| 1 | sslip.io가 고객망에서 차단 | 와일드카드 DNS 도메인 유해사이트 필터 등재 | Hostinger 기본 도메인 `srv1768237.hstgr.cloud`를 Caddy vhost에 추가 (DNS 기등록, 인증서 자동 발급) |
| 2 | librechat.yaml 미적용 (ENOENT) | 기본 compose에 yaml 마운트 없음 | override에 bind mount 추가 |
| 3 | MCP `Domain not allowed` | LibreChat SSRF 보호 | `mcpSettings.allowedDomains`에 도메인 명시 |
| 4 | MCP `fetch failed` (ECONNREFUSED 127.0.1.1) | 호스트 `/etc/hosts`의 자기 호스트네임=127.0.1.1을 컨테이너가 상속 | override `extra_hosts: srv1768237.hstgr.cloud:host-gateway` |
| 5 | 툴 0개 + OAuth 플로우 강제 | 무인증 프로브 401 → LibreChat이 OAuth 서버로 오판 | mcpServers 각각에 **`requiresOAuth: false`** 명시 |
| 6 | `${MCP_TOKEN}` 헤더 치환 미동작 | (원인 미상, v0.8.7) | librechat.yaml에 토큰 직접 기입 + `chmod 600` |

## 6. 운영 명령

| 작업 | 명령 (VPS) |
|------|------|
| 재시작 | `cd /opt/librechat && docker compose restart api` |
| 로그 | `docker logs -f LibreChat` (MCP 초기화: `docker logs LibreChat 2>&1 \| grep MCP`) |
| 정지/기동 | `docker compose stop` / `docker compose up -d api mongodb` |
| 계정 추가 | 가입 차단됨(`ALLOW_REGISTRATION=false`, 2026-07-09) — 필요 시 VPS `/opt/librechat/.env`에서 임시 `true` → `docker compose restart api` → 가입 후 원복 |

## 7. 시연 전 점검 체크리스트

```
□ https://srv1768237.hstgr.cloud/ 접속 → 로그인 화면
□ 로그인 → 모델 claude-sonnet-4.5 → MCP "2 selected"
□ 워밍업 질의 1회 (예: "loan_contract 몇 건이야?") — 콜드스타트 방지
□ 서버측: systemctl is-active lightrag postgres-mcp lightrag-mcp caddy && docker ps
□ (당일 아침) 킬러 질의 1종 리허설 — 6건 나오는지
```
