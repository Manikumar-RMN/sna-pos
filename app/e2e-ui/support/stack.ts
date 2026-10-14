/**
 * The whole stack for browser tests, all local and throw-away:
 *   PostgreSQL (migrations replayed) -> PostgREST (real) -> test gateway (sign-in) -> the real Next.js production build.
 * The PostgREST binary is not in the repo; scripts/fetch-postgrest.sh (or e2e-ui/README) says how to get it.
 */
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { existsSync, mkdirSync, openSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { startCluster, type Cluster } from "../../e2e/support/cluster";
import { getPool, closePool } from "../../e2e/support/db";
import { sign, startGateway } from "./authlite";
import type http from "node:http";

const APP = join(__dirname, "..", "..");
export const PORTS = { gateway: 54321, postgrest: 54320, app: 3100 };
const SECRET = "sna-pos-e2e-secret-sna-pos-e2e-secret-0123456789";

export type Stack = { cluster: Cluster; baseUrl: string; anonKey: string; stop: () => Promise<void> };

export function findPostgrest(): string | null {
  const c = [process.env.POSTGREST_BIN, join(APP, ".tools/postgrest"), "/usr/local/bin/postgrest"].filter(Boolean) as string[];
  return c.find((p) => existsSync(p)) ?? null;
}

async function waitFor(url: string, label: string, ms = 120000, log?: string) {
  const t0 = Date.now();
  for (;;) {
    try { const r = await fetch(url); if (r.status < 500) return; } catch { /* not up yet */ }
    if (Date.now() - t0 > ms) throw new Error(`${label} did not start within ${ms / 1000}s${log && existsSync(log) ? `\n${readFileSync(log, "utf8").slice(-1500)}` : ""}`);
    await new Promise((r) => setTimeout(r, 400));
  }
}

export async function startStack(): Promise<Stack | null> {
  const pgrst = findPostgrest();
  if (!pgrst) return null;
  const cluster = await startCluster();
  if (!cluster) return null;
  const procs: ChildProcess[] = [];
  let gateway: http.Server | null = null;
  const stop = async () => {
    for (const p of procs) { try { p.kill("SIGKILL"); } catch { /* gone */ } }
    gateway?.close();
    await closePool();
    cluster.stop();
  };
  try {
    process.env.E2E_PG_PORT = String(cluster.port);
    process.env.E2E_REST_LOG = join(cluster.dir, "rest-errors.log");
    const pool = getPool();
    await pool.query("create role authenticator login noinherit; grant anon, authenticated, service_role to authenticator");
    const logs = join(cluster.dir, "logs"); mkdirSync(logs, { recursive: true });
    const env = (extra: Record<string, string>) => ({ ...process.env, ...extra });

    const pr = spawn(pgrst, [], { env: env({ PGRST_DB_URI: `postgres://authenticator@127.0.0.1:${cluster.port}/e2e`, PGRST_DB_SCHEMAS: "public", PGRST_DB_ANON_ROLE: "anon", PGRST_JWT_SECRET: SECRET, PGRST_SERVER_PORT: String(PORTS.postgrest), PGRST_SERVER_HOST: "127.0.0.1", PGRST_DB_POOL: "10", PGRST_LOG_LEVEL: "warn" }), stdio: ["ignore", openSync(join(logs, "postgrest.log"), "w"), openSync(join(logs, "postgrest.log"), "a")] });
    procs.push(pr);
    gateway = await startGateway({ port: PORTS.gateway, postgrestPort: PORTS.postgrest, secret: SECRET });
    await waitFor(`http://127.0.0.1:${PORTS.postgrest}/`, "PostgREST", 30000, join(logs, "postgrest.log"));

    const anonKey = sign({ role: "anon", iss: "sna-e2e", iat: 1, exp: 4102444800 }, SECRET);
    const appEnv = { NEXT_PUBLIC_SUPABASE_URL: `http://127.0.0.1:${PORTS.gateway}`, NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: anonKey, NEXT_PUBLIC_SITE_URL: `http://127.0.0.1:${PORTS.app}`, NEXT_DIST_DIR: ".next-e2e", NEXT_TELEMETRY_DISABLED: "1" };
    if (!process.env.E2E_SKIP_BUILD || !existsSync(join(APP, ".next-e2e"))) {
      execFileSync("npx", ["next", "build"], { cwd: APP, env: env(appEnv), stdio: "pipe", timeout: 600000 });
    }
    const app = spawn("npx", ["next", "start", "-p", String(PORTS.app), "-H", "127.0.0.1"], { cwd: APP, env: env(appEnv), stdio: ["ignore", openSync(join(logs, "app.log"), "w"), openSync(join(logs, "app.log"), "a")] });
    procs.push(app);
    await waitFor(`http://127.0.0.1:${PORTS.app}/login`, "the app", 120000, join(logs, "app.log"));
    return { cluster, baseUrl: `http://127.0.0.1:${PORTS.app}`, anonKey, stop };
  } catch (e) { await stop(); throw e; }
}
