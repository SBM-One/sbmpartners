// Preview the phone app on your computer against a local test database, with no Supabase sign-in.
//   DATABASE_URL=postgres://… PREVIEW_EMAIL=you@example.com node scripts/phone_preview.mjs   → http://localhost:8788
// It serves phone/ and answers the app's /rest/v1/rpc/phone_* calls the way Supabase would, as PREVIEW_EMAIL.
// For local test data only: never point it at the real database.
import http from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { createRequire } from "node:module";

const require = createRequire(new URL("../dashboard/package.json", import.meta.url));
const pg = require("postgres");
const postgres = pg.default ?? pg;
const sql = postgres(process.env.DATABASE_URL, { max: 4 });
const EMAIL = process.env.PREVIEW_EMAIL || "yago@sbm-demo.example";
const PORT = Number(process.env.PORT || 8788);
const ROOT = new URL("../phone/", import.meta.url).pathname;
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".png": "image/png", ".woff2": "font/woff2",
  ".webmanifest": "application/manifest+json" };

http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const m = url.pathname.match(/^\/rest\/v1\/rpc\/(phone_[a-z_]+)$/);
  if (m) {
    let body = "";
    for await (const c of req) body += c;
    const args = body ? JSON.parse(body) : {};
    try {
      const rows = await sql.begin(async (tx) => {
        await tx`select set_config('request.jwt.claims', ${JSON.stringify({ email: EMAIL, role: "authenticated" })}, true)`;
        await tx`set local role authenticated`;
        const names = Object.keys(args);
        const call = names.map((k, i) => `${k} => $${i + 1}`).join(", ");
        return tx.unsafe(`select ${m[1]}(${call}) as r`, names.map((k) => args[k]));
      });
      res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify(rows[0].r ?? null));
    } catch (e) {
      res.writeHead(400, { "Content-Type": "application/json" }).end(JSON.stringify({ message: e.message }));
    }
    return;
  }
  if (url.pathname === "/config.js") {
    res.writeHead(200, { "Content-Type": "text/javascript" })
      .end(`window.SBM = { supabaseUrl: "http://localhost:${PORT}", anonKey: "preview", dev: true };`);
    return;
  }
  const path = normalize(join(ROOT, url.pathname === "/" ? "index.html" : url.pathname));
  if (!path.startsWith(ROOT)) return res.writeHead(403).end();
  try {
    res.writeHead(200, { "Content-Type": TYPES[extname(path)] || "application/octet-stream" }).end(await readFile(path));
  } catch {
    res.writeHead(404).end("Not found");
  }
}).listen(PORT, () => console.log(`Phone app preview: http://localhost:${PORT}  (signed in as ${EMAIL})`));
