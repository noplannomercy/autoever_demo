// LightRAG KB 청소: 보존 접두(회수규정_/역문서_) 데모 문서만 남기고 나머지(옛 문서/오염분) 전부 삭제.
// 실행:
//   node clean_kb.mjs          → dry-run (무엇을 지울지 보기만)
//   node clean_kb.mjs --yes    → 실제 삭제
const BASE = (process.env.LIGHTRAG_BASE_URL || "http://127.0.0.1:9621").replace(/\/$/, "");
const KEEP_PREFIXES = ["회수규정_", "역문서_"];   // 이 접두 파일만 보존 (역문서_ = 7막 레거시 패키지)
const apply = process.argv.includes("--yes");

const res = await fetch(`${BASE}/documents`);
const data = await res.json();

// 응답 구조가 버전마다 다를 수 있어 평탄화 (id + file_path 가진 객체만 수집)
const docs = [];
const walk = (o) => {
  if (Array.isArray(o)) o.forEach(walk);
  else if (o && typeof o === "object") {
    if (o.id && (o.file_path || o.file_source)) docs.push(o);
    else Object.values(o).forEach(walk);
  }
};
walk(data);

const uniq = new Map();
for (const d of docs) uniq.set(d.id, d.file_path || d.file_source || "");

const keep = [], drop = [];
for (const [id, fp] of uniq) (KEEP_PREFIXES.some((p) => String(fp).startsWith(p)) ? keep : drop).push({ id, fp });

console.log(`총 ${uniq.size}개 | 보존 ${keep.length} | 삭제대상 ${drop.length}`);
console.log("\n[보존]");
keep.forEach((k) => console.log("  ✔", k.fp));
console.log("\n[삭제대상]");
drop.forEach((d) => console.log("  ✘", d.fp));

if (!apply) {
  console.log("\n(dry-run) 실제로 지우려면:  node clean_kb.mjs --yes");
  process.exit(0);
}
if (!drop.length) { console.log("\n삭제할 거 없음. 이미 깨끗함."); process.exit(0); }

const del = await fetch(`${BASE}/documents/delete_document`, {
  method: "DELETE",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ doc_ids: drop.map((d) => d.id), delete_file: true, delete_llm_cache: true }),
});
console.log(`\n삭제요청: HTTP ${del.status}  ${(await del.text()).slice(0, 300)}`);
console.log("※ 그래프 재생성에 시간이 걸릴 수 있음. 잠시 후 GET /documents로 3개만 남았는지 확인.");
