// MCP server: exposes LightRAG /query as a single tool.
// Transport: Streamable HTTP (stateless). Runs server-side on the VPS.
// Env:
//   LIGHTRAG_BASE_URL (required, e.g. http://127.0.0.1:9621)
//   LIGHTRAG_API_KEY  (optional)
//   MCP_TOKEN         (required) Bearer token clients must present
//   PORT              (optional) default 8012
//   MCP_PATH          (optional) default /mcp
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import express from "express";

const BASE = (process.env.LIGHTRAG_BASE_URL || "").replace(/\/$/, "");
const KEY = process.env.LIGHTRAG_API_KEY || "";
const TOKEN = process.env.MCP_TOKEN || "";
const PORT = Number(process.env.PORT || 8012);
const HOST = process.env.HOST || "127.0.0.1"; // Caddy가 앞단 — 직접 노출 금지
const MCP_PATH = process.env.MCP_PATH || "/mcp";
if (!BASE) {
  console.error("[lightrag-mcp] LIGHTRAG_BASE_URL not set — refusing to start");
  process.exit(1);
}
if (!TOKEN) {
  console.error("[lightrag-mcp] MCP_TOKEN not set — refusing to start (no anonymous access)");
  process.exit(1);
}

function createMcpServer() {
  const server = new McpServer({ name: "lightrag", version: "0.1.0" });

  server.tool(
    "lightrag_query",
    "Query the LightRAG knowledge base of business rules / reverse-documentation. " +
      "Use for 'why / what does the policy or rule say' questions — NOT for live row data. " +
      "Returns the answer WITH inline source-document citations and a References list " +
      "(e.g. [[4] 규칙_01_중도해지_위약금.md]). Always surface those citations to the user.",
    {
      query: z.string().describe("natural-language question to ask the knowledge base"),
      mode: z
        .enum(["mix", "hybrid", "local", "global", "naive"])
        .default("mix")
        .describe("retrieval mode; 'mix' = vector + graph (recommended)"),
    },
    async ({ query, mode }) => {
      const headers = { "Content-Type": "application/json" };
      if (KEY) headers["X-API-Key"] = KEY;
      try {
        const res = await fetch(`${BASE}/query`, {
          method: "POST",
          headers,
          body: JSON.stringify({ query, mode, include_references: true }),
        });
        const text = await res.text();
        if (!res.ok) {
          return {
            content: [{ type: "text", text: `LightRAG HTTP ${res.status}: ${text}` }],
            isError: true,
          };
        }
        let out = text;
        try {
          const j = JSON.parse(text);
          out = j.response ?? j.data ?? j.result ?? text;
          // 실제 인용된 출처 문서만 추려 명시적으로 덧붙임 (환각 방지 / 근거 강제)
          if (Array.isArray(j.references) && j.references.length) {
            const cited = new Set(
              [...String(out).matchAll(/\[(\d+)\]/g)].map((m) => m[1])
            );
            const used = j.references.filter((r) => cited.has(String(r.reference_id)));
            const list = (used.length ? used : j.references)
              .map((r) => `  [${r.reference_id}] ${r.file_path}`)
              .join("\n");
            out = `${out}\n\n── 출처 문서 (LightRAG 검색) ──\n${list}`;
          }
        } catch {
          /* plain text response */
        }
        return { content: [{ type: "text", text: String(out) }] };
      } catch (e) {
        return {
          content: [{ type: "text", text: `LightRAG request failed: ${e?.message || e}` }],
          isError: true,
        };
      }
    }
  );

  return server;
}

const app = express();
app.use(express.json({ limit: "4mb" }));

app.get("/healthz", (_req, res) => res.json({ ok: true, name: "lightrag-mcp", base: BASE }));

app.use(MCP_PATH, (req, res, next) => {
  const auth = req.headers["authorization"] || "";
  if (auth !== `Bearer ${TOKEN}`) {
    return res.status(401).json({ error: "unauthorized" });
  }
  next();
});

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
    console.error("[lightrag-mcp] request error:", e?.message || e);
    if (!res.headersSent) res.status(500).json({ error: "internal" });
  }
});

const reject = (_req, res) => res.status(405).json({ error: "method not allowed (stateless)" });
app.get(MCP_PATH, reject);
app.delete(MCP_PATH, reject);

app.listen(PORT, HOST, () => {
  console.error(`[lightrag-mcp] HTTP listening ${HOST}:${PORT}${MCP_PATH} → ${BASE}`);
});
