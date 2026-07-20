# HANDOFF — 서버사이드 MCP 배포 이어받기

> 작성: 2026-06-19. 로컬에서 코드 완성 + VPS 업로드까지 끝낸 상태. 다음 작업자(VPS의 Claude)가 배포 마무리.

## 지금 상태

- **파일 전부 `/opt/autoever_demo/` 에 업로드됨** (node_modules 제외, 23개). 코드는 로컬에서 부팅/인증/tools-list 검증 완료.
- **`demo_legacy` DB 이미 존재** (어제 합성데이터·갭 적재됨, postgres-vector 컨테이너 호스트 5434).
- **LightRAG** `http://127.0.0.1:9621` 가동 중(키 없음).

## ⚠️ 먼저 할 일 — Node 미설치

VPS 호스트에 node가 없다. systemd가 `/usr/bin/node`를 쓰므로 설치 필요:
```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs
node -v   # v20.x 확인
```

## 배포 순서 — 상세는 `deploy/README.md`

1. `cd /opt/autoever_demo/postgres-mcp && npm install --omit=dev`
   `cd /opt/autoever_demo/lightrag-mcp && npm install --omit=dev`
2. env 2개 생성. **반드시 `.env.example`을 통째 복사**하고 토큰만 교체할 것
   (PORT·MCP_PATH·HOST가 빠지면 Caddy 라우팅이 어긋나 404 — 손타이핑 금지):
   ```bash
   cp deploy/postgres-mcp.env.example postgres-mcp.env
   cp deploy/lightrag-mcp.env.example lightrag-mcp.env
   sed -i 's/CHANGE_ME_PASTE_TOKEN/<MCP_TOKEN>/' postgres-mcp.env lightrag-mcp.env
   chmod 600 postgres-mcp.env lightrag-mcp.env
   ```
   - PG_CONN 포트 = **5434** (VPS 직결, 터널 아님). 이미 example에 박혀 있음.
3. systemd: `cp deploy/*.service /etc/systemd/system/ && systemctl daemon-reload && systemctl enable --now postgres-mcp lightrag-mcp`
   - 로컬 확인: `curl localhost:8011/healthz` / `curl localhost:8012/healthz` → `{"ok":true,...}`
4. Caddy(HTTPS, 도메인 없이 sslip.io). **`{$MCP_DOMAIN}`은 셸 export로 안 먹으니 Caddyfile에 직접 박을 것:**
   ```bash
   apt-get install -y caddy
   cp deploy/Caddyfile /etc/caddy/Caddyfile
   sed -i 's/{$MCP_DOMAIN}/76-13-214-57.sslip.io/' /etc/caddy/Caddyfile
   ufw allow 80/tcp && ufw allow 443/tcp     # 80=ACME 챌린지, 443=서빙
   systemctl restart caddy
   ```
   - ⚠️ 클라우드 보안그룹(있다면)에서도 80/443 인바운드 허용 필요(ufw만으론 부족할 수 있음).
5. **최종 검증 — `/healthz`는 프리픽스 밑에 없으니 외부는 MCP 엔드포인트로 확인:**
   ```bash
   curl -s -X POST https://76-13-214-57.sslip.io/postgres/mcp \
     -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
     -H "Authorization: Bearer <MCP_TOKEN>" \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
   # → event: message ... "pg_query","pg_execute" 나오면 DNS+TLS+Caddy+인증+서버 전부 OK
   ```
   lightrag도 동일하게 `/lightrag/mcp` 로 한 번 확인.

## 로컬(사용자 노트북)에서

`opencode.json` 에 이미 `https://76-13-214-57.sslip.io/{postgres,lightrag}/mcp` + 토큰이 박혀 있음.
배포 끝나면 `autoever_demo` 폴더에서 그냥 `opencode` → SSH 터널/로컬 node 불필요.

## 주의

- 두 서버는 127.0.0.1 바인딩(앞단 Caddy). 직접 외부노출 금지.
- 포트 80을 못 열면 Caddyfile `tls internal`(자체서명)+`NODE_TLS_REJECT_UNAUTHORIZED=0 opencode`, 또는 cloudflared.
- 롤백: 각 폴더 `server-stdio.mjs.bak` → `server.mjs` 복사하면 옛 stdio 로컬모드.
