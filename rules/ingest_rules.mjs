// 회수규정 마크다운(현재 13장, rules/회수규정_*.md)을 LightRAG KB에 적재.
// LightRAG는 file_source로 중복 감지 → 동일 파일 재적재 시 409로 스킵(신규만 200).
// 실행: node ingest_rules.mjs
// (필요 시) set LIGHTRAG_BASE_URL=http://127.0.0.1:9621 && node ingest_rules.mjs
import { readFileSync, readdirSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const BASE = (process.env.LIGHTRAG_BASE_URL || "http://127.0.0.1:9621").replace(/\/$/, "");
const KEY = process.env.LIGHTRAG_API_KEY || "";
const dir = dirname(fileURLToPath(import.meta.url));
const files = readdirSync(dir).filter((f) => f.endsWith(".md"));

const headers = { "Content-Type": "application/json" };
if (KEY) headers["X-API-Key"] = KEY;

console.log(`LightRAG: ${BASE}  |  적재할 규칙 ${files.length}개`);
for (const f of files) {
  const text = readFileSync(join(dir, f), "utf-8");
  try {
    const res = await fetch(`${BASE}/documents/text`, {
      method: "POST",
      headers,
      body: JSON.stringify({ text, file_source: f }),
    });
    const body = (await res.text()).slice(0, 200);
    console.log(`  [${res.status}] ${f}  ${body}`);
  } catch (e) {
    console.log(`  [ERR] ${f}  ${e?.message || e}`);
  }
}
console.log("끝. LightRAG는 백그라운드로 인덱싱하니 1~2분 후 /query로 확인.");
console.log("※ 404면 적재 엔드포인트가 다른 버전 — http://<host>:9621/docs (Swagger)에서 경로 확인 후 수정.");
