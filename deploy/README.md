# 서버사이드 MCP 배포 — OpenCode → VPS의 HTTP MCP 2종

> 목표: MCP 서버를 **VPS에서 통제**(systemd) + **Caddy HTTPS/토큰**으로 노출.
> 로컬엔 node 프로세스도 SSH 터널도 없음 — OpenCode는 URL 2개만 본다.

## 구조

```
[로컬 OpenCode] ──HTTPS+Bearer──▶ [VPS Caddy :443]
                                     ├─ /postgres/* → 127.0.0.1:8011 (postgres-mcp) → 127.0.0.1:5434 DB
                                     └─ /lightrag/* → 127.0.0.1:8012 (lightrag-mcp) → 127.0.0.1:9621 LightRAG
```

- postgres-mcp가 DB와 **같은 박스**에서 돌므로 SSH 터널 불필요 (localhost:5434 직결).
- 두 node 서버는 `127.0.0.1`에만 바인딩 → 외부 진입점은 Caddy(토큰 검증은 node가, TLS는 Caddy가).

## 토큰

이미 생성됨 (opencode.json·env에 반영):
```
<MCP_TOKEN>
```
교체하려면 `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"` → env 2개 + opencode.json 헤더 갱신.

---

## STEP 1 — 코드·노드 올리기 (VPS)

```bash
# 로컬에서 (node_modules 제외하고 동기화)
rsync -av --exclude node_modules \
  "C:/workspace/doc_root/HCA_Code2Rule/05_Phase3_구현/autoever_demo/postgres-mcp" \
  "C:/workspace/doc_root/HCA_Code2Rule/05_Phase3_구현/autoever_demo/lightrag-mcp" \
  root@72.62.242.236:/opt/autoever_demo/

# VPS에서
ssh root@72.62.242.236
which node || (curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs)
cd /opt/autoever_demo/postgres-mcp && npm install --omit=dev
cd /opt/autoever_demo/lightrag-mcp && npm install --omit=dev
```

## STEP 2 — env 파일 (VPS, chmod 600)

`deploy/postgres-mcp.env.example` · `lightrag-mcp.env.example` 를 참고해 실제 토큰 박아 생성:
```bash
install -m600 /dev/null /opt/autoever_demo/postgres-mcp.env   # 내용은 example 참고
install -m600 /dev/null /opt/autoever_demo/lightrag-mcp.env
```

## STEP 3 — systemd 등록

```bash
cp /opt/autoever_demo/deploy/*.service /etc/systemd/system/   # 또는 수동 작성
systemctl daemon-reload
systemctl enable --now postgres-mcp lightrag-mcp
systemctl status postgres-mcp lightrag-mcp --no-pager
# 로컬 헬스 확인
curl -s localhost:8011/healthz; curl -s localhost:8012/healthz
```

## STEP 4 — Caddy (HTTPS) — 도메인 없이 sslip.io 사용

이 VPS엔 도메인이 없으므로 **무료 와일드카드 DNS `sslip.io`** 로 IP를 호스트네임화한다.
`72-62-242-236.sslip.io` 는 자동으로 `72.62.242.236` 로 resolve → Caddy가
이 호스트네임으로 **Let's Encrypt 진짜 인증서를 발급**(OpenCode가 그대로 신뢰).

```bash
apt-get install -y caddy        # 없으면
# Caddyfile의 {$MCP_DOMAIN} 에 sslip 호스트네임 주입
export MCP_DOMAIN=72-62-242-236.sslip.io
cp /opt/autoever_demo/deploy/Caddyfile /etc/caddy/Caddyfile
# 방화벽: 80(인증서 발급 챌린지) + 443(서빙) 개방 — 둘 다 필수
ufw allow 80/tcp && ufw allow 443/tcp
systemctl restart caddy
```
1분 내 `curl https://72-62-242-236.sslip.io/postgres/healthz` → 200.
> Caddy가 systemd 환경변수 `MCP_DOMAIN` 을 못 읽으면 `/etc/caddy/Caddyfile` 의
> `{$MCP_DOMAIN}` 을 `72-62-242-236.sslip.io` 로 직접 치환해도 됨.

**폴백 — 80포트를 못 열 때:** Caddyfile 하단 `tls internal`(자체서명) 블록 사용 +
OpenCode를 `NODE_TLS_REJECT_UNAUTHORIZED=0 opencode` 로 실행(데모 한정, 보안 약화).
또는 `cloudflared tunnel --url http://localhost:8011` (포트 개방 불필요, 단 URL이 재시작마다 바뀜).

## STEP 5 — OpenCode 연결 (로컬)

`opencode.json` 엔 이미 `https://72-62-242-236.sslip.io/...` 가 박혀 있다. 그대로 실행:
```bash
# 로컬 autoever_demo 폴더에서
opencode
```
OpenCode 안:
```
사용 가능한 MCP 툴 보여줘     # postgres(pg_query/pg_execute) + lightrag_query 떠야 함
```

## STEP 6 — 검증

```
postgres 툴로 demo_legacy 테이블 목록 보여줘
lightrag_query로 "중도해지 위약금 규칙이 뭐야?" 물어봐
```
둘 다 응답 = **서버사이드 플러밍 완성.** 이후 SSH 터널/로컬 node 일절 불필요.

---

## 운영 명령

| 작업 | 명령 |
|------|------|
| 재시작 | `systemctl restart postgres-mcp lightrag-mcp` |
| 로그 | `journalctl -u postgres-mcp -f` |
| 정지 | `systemctl stop postgres-mcp lightrag-mcp` |
| 토큰 교체 | env 2개 + opencode.json 헤더 갱신 → `systemctl restart` |

## 트러블슈팅

| 증상 | 조치 |
|------|------|
| OpenCode에 툴 안 뜸 | `curl https://$MCP_DOMAIN/postgres/healthz` 200 확인 / 토큰 일치 확인 |
| 401 | opencode.json Bearer ↔ env MCP_TOKEN 불일치 |
| 502 (Caddy) | node 서비스 죽음 — `systemctl status` |
| TLS 에러 | 자체서명 사용 중 → 도메인+LetsEncrypt로 전환 |
| postgres 연결거부 | VPS에서 5434 포트/`demo_legacy` 존재 확인 |

---

## 부록 — 로컬 모드(구버전)로 되돌리려면

stdio 트랜스포트 시절 `opencode.json` (SSH 터널 + 로컬 node):
```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "postgres": { "type": "local",
      "command": ["node", ".../postgres-mcp/server.mjs"],
      "environment": { "PG_CONN": "postgresql://postgres:<PG_PASSWORD>@127.0.0.1:15432/demo_legacy" },
      "enabled": true },
    "lightrag": { "type": "local",
      "command": ["node", ".../lightrag-mcp/server.mjs"],
      "environment": { "LIGHTRAG_BASE_URL": "http://72.62.242.236:9621" },
      "enabled": true }
  }
}
```
> 현재 server.mjs는 HTTP 전용. 로컬 stdio로 되돌리려면 각 폴더의
> `server-stdio.mjs.bak` 을 `server.mjs` 로 복사하면 된다.
