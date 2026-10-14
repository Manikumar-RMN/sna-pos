import { randomUUID } from "node:crypto";
import pg from "pg";

const port = () => Number(process.env.E2E_PG_PORT);
export const haveDb = () => !!process.env.E2E_PG_PORT;

let pool: pg.Pool | null = null;
export function getPool() {
  pool ??= new pg.Pool({ host: "/tmp", port: port(), user: "postgres", database: "e2e", max: 30 });
  return pool;
}
export async function closePool() { await pool?.end(); pool = null; }

/** Runs SQL as the database owner: used only to set the scene, never to test behaviour. */
export async function admin<T = any>(sql: string, params: unknown[] = []): Promise<T[]> {
  return (await getPool().query(sql, params)).rows as T[];
}

/** Runs SQL as the database owner with a person's id in the JWT claims (how the SNA console, using the service role, sets a restaurant up for them). */
export async function adminAs<T = any>(authId: string, sql: string, params: unknown[] = []): Promise<T[]> {
  const client = await getPool().connect();
  try {
    await client.query("begin");
    await client.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify({ sub: authId, role: "authenticated" })]);
    const r = await client.query(sql, params);
    await client.query("commit");
    return r.rows as T[];
  } catch (e) {
    await client.query("rollback").catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

/**
 * Runs `fn` exactly as the app does for a signed-in person: role `authenticated`, with that person's id in the JWT
 * claims, so Row Level Security, permissions and every grant apply. One transaction; rolled back if `fn` throws.
 */
export async function asUser<T>(authId: string, fn: (q: (sql: string, params?: unknown[]) => Promise<pg.QueryResult>) => Promise<T>): Promise<T> {
  const client = await getPool().connect();
  try {
    await client.query("begin");
    await client.query("set local role authenticated");
    await client.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify({ sub: authId, role: "authenticated" })]);
    const out = await fn((sql, params) => client.query(sql, params));
    await client.query("commit");
    return out;
  } catch (e) {
    await client.query("rollback").catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

/** One call to a database function as a person, returning its single value (the jsonb the app receives). */
export async function rpc<T = any>(authId: string, fn: string, args: unknown[] = []): Promise<T> {
  const ph = args.map((_, i) => `$${i + 1}`).join(", ");
  return asUser(authId, async (q) => {
    const r = await q(`select public.${fn}(${ph}) as v`, args.map((a) => (a !== null && typeof a === "object" ? JSON.stringify(a) : a)));
    return r.rows[0].v as T;
  });
}

export const uuid = () => randomUUID();
