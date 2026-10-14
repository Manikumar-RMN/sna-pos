/**
 * A throw-away PostgreSQL for the end-to-end tests: starts a private cluster in a temp folder, loads the stand-ins for
 * what Supabase provides (supabase/verify/stubs.sql) and replays every migration. Nothing outside the temp folder is touched.
 * Needs PostgreSQL 16+ server binaries (initdb, pg_ctl); returns null when they are not installed so the tests can skip.
 */
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import pg from "pg";

const REPO = join(__dirname, "..", "..", "..");
const PORT = 5493;

export function findBin(): string | null {
  const roots = ["/usr/lib/postgresql", "/opt/homebrew/opt", "/usr/local/opt"];
  const found: string[] = [];
  for (const r of roots) {
    if (!existsSync(r)) continue;
    for (const d of readdirSync(r)) {
      const bin = r === "/usr/lib/postgresql" ? join(r, d, "bin") : d.startsWith("postgresql") ? join(r, d, "bin") : "";
      if (bin && existsSync(join(bin, "initdb"))) found.push(bin);
    }
  }
  return found.sort((a, b) => a.localeCompare(b, undefined, { numeric: true })).pop() ?? null;
}

const asRoot = () => typeof process.getuid === "function" && process.getuid() === 0;
function run(cmd: string, args: string[]) {
  // initdb refuses to run as root; the cluster then belongs to the `postgres` user
  if (asRoot()) execFileSync("su", ["postgres", "-c", [cmd, ...args].map((a) => `'${a}'`).join(" ")], { stdio: "pipe" });
  else execFileSync(cmd, args, { stdio: "pipe" });
}

export type Cluster = { dir: string; bin: string; port: number; stop: () => void };

export async function startCluster(): Promise<Cluster | null> {
  const bin = findBin();
  if (!bin) return null;
  const dir = mkdtempSync(join(tmpdir().startsWith("/tmp") ? "/var/tmp" : tmpdir(), "sna-e2e-"));
  chmodSync(dir, 0o755);
  if (asRoot()) execFileSync("chown", ["postgres", dir]);
  const data = join(dir, "data");
  run(join(bin, "initdb"), ["-D", data, "-A", "trust"]);
  run(join(bin, "pg_ctl"), ["-D", data, "-o", `-p ${PORT} -k /tmp`, "-l", join(dir, "log"), "-w", "start"]);
  const stop = () => {
    try { run(join(bin, "pg_ctl"), ["-D", data, "-m", "immediate", "stop"]); } catch { /* already stopped */ }
    rmSync(dir, { recursive: true, force: true });
  };
  try {
    const root = new pg.Client({ host: "/tmp", port: PORT, user: "postgres", database: "postgres" });
    await root.connect();
    await root.query("create database e2e");
    await root.end();
    const c = new pg.Client({ host: "/tmp", port: PORT, user: "postgres", database: "e2e" });
    await c.connect();
    await c.query(readFileSync(join(REPO, "supabase/verify/stubs.sql"), "utf8").replace(/create role (anon|authenticated|service_role)[^;]*;/g, ""));
    await c.query("create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls");
    await c.query("alter database e2e set search_path = public, extensions");
    await c.query("set search_path = public, extensions");
    // what Supabase gives every new object in public
    for (const k of ["tables", "functions", "sequences"])
      await c.query(`alter default privileges for role postgres in schema public grant all on ${k} to anon, authenticated, service_role`);
    const files = readdirSync(join(REPO, "supabase/migrations")).filter((f) => f.endsWith(".sql")).sort((a, b) => (a < b ? -1 : 1));
    const last = Number(process.env.E2E_LAST_MIGRATION || 9999); // lets a test run against an older database, e.g. to prove it would have caught a bug
    for (const f of files.filter((f) => Number.parseInt(f, 10) <= last)) {
      const sql = readFileSync(join(REPO, "supabase/migrations", f), "utf8").replace(/^[ \t]*create extension if not exists (pg_net|pg_cron)[^\n]*$/gim, "");
      try { await c.query(sql); } catch (e) { throw new Error(`Migration ${f} failed: ${(e as Error).message}`); }
    }
    await c.end();
  } catch (e) { stop(); throw e; }
  return { dir, bin, port: PORT, stop };
}
