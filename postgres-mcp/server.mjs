// Postgres MCP (read + write), scoped to one DB via PG_CONN.
// Transport: Streamable HTTP (stateless). Runs server-side on the VPS.
// Env:
//   PG_CONN   (required) e.g. postgresql://postgres:<PG_PASSWORD>@127.0.0.1:5434/demo_legacy
//   MCP_TOKEN (required) Bearer token clients must present
//   PORT      (optional) default 8011
//   MCP_PATH  (optional) default /mcp
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import express from "express";
import pg from "pg";

const CONN = process.env.PG_CONN || "";
const TOKEN = process.env.MCP_TOKEN || "";
const PORT = Number(process.env.PORT || 8011);
const HOST = process.env.HOST || "127.0.0.1"; // Caddy가 앞단 — 직접 노출 금지
const MCP_PATH = process.env.MCP_PATH || "/mcp";
if (!CONN) {
  console.error("[postgres-mcp] PG_CONN not set — refusing to start");
  process.exit(1);
}
if (!TOKEN) {
  console.error("[postgres-mcp] MCP_TOKEN not set — refusing to start (no anonymous access)");
  process.exit(1);
}
const pool = new pg.Pool({ connectionString: CONN, max: 4 });

const fmt = (res) => {
  if (Array.isArray(res.rows) && res.rows.length) {
    const rows = res.rows.slice(0, 200); // 과다 출력 방지
    let out = JSON.stringify(rows, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2);
    if (res.rows.length > 200) out += `\n... (${res.rows.length}행 중 200행만 표시)`;
    return out;
  }
  return `OK — command=${res.command}, rowCount=${res.rowCount}`;
};

// 요청마다 새 서버 인스턴스 (stateless — 요청 ID 충돌 방지)
function createMcpServer() {
  const server = new McpServer({ name: "postgres", version: "0.1.0" });

  // 읽기 전용 조회
  server.tool(
    "pg_query",
    "Run a READ-ONLY SQL query (SELECT/WITH/EXPLAIN) against the demo_legacy DB. Returns rows as JSON. " +
      "Use this for all lookups and analysis. For writes use pg_execute.",
    { sql: z.string().describe("a SELECT / WITH / EXPLAIN statement") },
    async ({ sql }) => {
      if (!/^\s*(select|with|explain)\b/i.test(sql)) {
        return {
          content: [{ type: "text", text: "pg_query는 읽기 전용입니다. 쓰기는 pg_execute를 쓰세요." }],
          isError: true,
        };
      }
      try {
        return { content: [{ type: "text", text: fmt(await pool.query(sql)) }] };
      } catch (e) {
        return { content: [{ type: "text", text: `SQL error: ${e.message}` }], isError: true };
      }
    }
  );

  // 쓰기/DDL — 명시적 데이터 핸들링 요청에만
  server.tool(
    "pg_execute",
    "Run a WRITING SQL statement (INSERT/UPDATE/DELETE/CREATE/ALTER/DROP) against demo_legacy. " +
      "Use ONLY when the user explicitly asks to change/insert/fix/delete data. " +
      "Returns affected rowCount. Scoped to demo_legacy only (pylon_dev은 접근 불가).",
    { sql: z.string().describe("an INSERT/UPDATE/DELETE/DDL statement") },
    async ({ sql }) => {
      if (/^\s*(select|with|explain)\b/i.test(sql)) {
        return {
          content: [{ type: "text", text: "조회는 pg_query를 쓰세요." }],
          isError: true,
        };
      }
      try {
        return { content: [{ type: "text", text: fmt(await pool.query(sql)) }] };
      } catch (e) {
        return { content: [{ type: "text", text: `SQL error: ${e.message}` }], isError: true };
      }
    }
  );

  return server;
}

const app = express();
app.use(express.json({ limit: "4mb" }));

// 헬스체크 (인증 불필요) — Caddy/모니터링용
app.get("/healthz", (_req, res) => res.json({ ok: true, name: "postgres-mcp" }));

// Bearer 인증
app.use(MCP_PATH, (req, res, next) => {
  const auth = req.headers["authorization"] || "";
  if (auth !== `Bearer ${TOKEN}`) {
    return res.status(401).json({ error: "unauthorized" });
  }
  next();
});

// Streamable HTTP — stateless: 요청마다 새 server+transport
app.post(MCP_PATH, async (req, res) => {
  const server = createMcpServer();
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  res.on("close", () => {
    transport.close();
    server.close();
  });
  try {
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
  } catch (e) {
    console.error("[postgres-mcp] request error:", e?.message || e);
    if (!res.headersSent) res.status(500).json({ error: "internal" });
  }
});

// stateless 모드에선 GET(SSE)/DELETE(세션종료) 불필요
const reject = (_req, res) => res.status(405).json({ error: "method not allowed (stateless)" });
app.get(MCP_PATH, reject);
app.delete(MCP_PATH, reject);

app.listen(PORT, HOST, () => {
  console.error(`[postgres-mcp] HTTP listening ${HOST}:${PORT}${MCP_PATH} (read+write, demo_legacy)`);
});
