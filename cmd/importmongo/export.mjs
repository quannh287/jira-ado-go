// Read-only export of the sync collections to JSON. Secrets from .env are never written.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { createRequire } from "node:module";
const [repo, out] = process.argv.slice(2);
const require = createRequire(repo + "/package.json");
const { MongoClient } = require("mongodb");
const env = Object.fromEntries(readFileSync(repo + "/.env", "utf8").split("\n")
  .filter(l => /^[A-Z_]+=/.test(l)).map(l => { const i = l.indexOf("="); return [l.slice(0, i), l.slice(i + 1).replace(/^["']|["']$/g, "")]; }));
mkdirSync(out, { recursive: true });
const client = new MongoClient(env.MONGODB_URI, { serverSelectionTimeoutMS: 15000 });
await client.connect();
const db = client.db(env.MONGODB_DB || "sync_jira_ado");
for (const name of ["syncJobs", "sync_state", "comment_mappings", "sync_runs", "sync_ticket_results", "ado_logs"]) {
  const docs = await db.collection(name).find({}).toArray();
  writeFileSync(`${out}/${name}.json`, JSON.stringify(docs));
  console.log(`${name}: ${docs.length}`);
}
// Non-secret connection settings the source read from env.
const settings = {};
for (const k of ["ADO_ORG", "ADO_PROJECT", "ADO_JIRA_KEY_FIELD", "JIRA_BASE_URL", "JIRA_EMAIL", "JIRA_JQL_EXTRA"]) settings[k] = env[k] ?? "";
writeFileSync(`${out}/settings.json`, JSON.stringify(settings, null, 2));
await client.close();
