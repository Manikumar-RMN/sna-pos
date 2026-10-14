/**
 * A small local stand-in for the Supabase gateway, so the real app can run against a real PostgREST and a real database:
 *   /auth/v1/*  -> password sign-in, token refresh, "who am I", sign-out (the only parts of Supabase Auth the app uses)
 *   /rest/v1/*  -> straight through to PostgREST (the real thing)
 * Passwords are checked against auth.users.encrypted_password with pgcrypto, exactly as Supabase Auth stores them.
 */
import { createHmac, randomUUID, randomBytes } from "node:crypto";
import http from "node:http";
import { appendFileSync } from "node:fs";
import { getPool } from "../../e2e/support/db";

const b64 = (b: Buffer | string) => Buffer.from(b).toString("base64url");
export function sign(payload: object, secret: string) {
  const head = b64(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const body = b64(JSON.stringify(payload));
  const sig = createHmac("sha256", secret).update(`${head}.${body}`).digest("base64url");
  return `${head}.${body}.${sig}`;
}
function verify(token: string, secret: string): Record<string, any> | null {
  const [h, p, s] = token.split(".");
  if (!h || !p || !s) return null;
  if (createHmac("sha256", secret).update(`${h}.${p}`).digest("base64url") !== s) return null;
  const pl = JSON.parse(Buffer.from(p, "base64url").toString());
  return pl.exp && pl.exp * 1000 < Date.now() ? null : pl;
}

export function startGateway(opts: { port: number; postgrestPort: number; secret: string }) {
  const refresh = new Map<string, string>(); // refresh token -> user id
  const userJson = (u: any) => ({ id: u.id, aud: "authenticated", role: "authenticated", email: u.email, email_confirmed_at: u.created_at, phone: "", app_metadata: { provider: "email", providers: ["email"] }, user_metadata: {}, identities: [], created_at: u.created_at, updated_at: u.created_at, is_anonymous: false });
  const session = (u: any) => {
    const now = Math.floor(Date.now() / 1000), exp = now + 3600;
    const access = sign({ aud: "authenticated", exp, iat: now, iss: `http://127.0.0.1:${opts.port}/auth/v1`, sub: u.id, email: u.email, role: "authenticated", aal: "aal1", session_id: randomUUID(), is_anonymous: false, app_metadata: { provider: "email" }, user_metadata: {} }, opts.secret);
    const r = randomBytes(8).toString("hex");
    refresh.set(r, u.id);
    return { access_token: access, token_type: "bearer", expires_in: 3600, expires_at: exp, refresh_token: r, user: userJson(u) };
  };
  const send = (res: http.ServerResponse, code: number, body: unknown) => { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(body)); };
  const readBody = (req: http.IncomingMessage) => new Promise<string>((ok) => { const c: Buffer[] = []; req.on("data", (d) => c.push(d)); req.on("end", () => ok(Buffer.concat(c).toString())); });

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", "http://x");
    try {
      if (url.pathname.startsWith("/auth/v1/")) {
        const route = url.pathname.slice("/auth/v1/".length);
        if (route === "token") {
          const body = JSON.parse((await readBody(req)) || "{}");
          const grant = url.searchParams.get("grant_type");
          if (grant === "password") {
            const { rows } = await getPool().query("select id, email, created_at, encrypted_password = extensions.crypt($2, encrypted_password) as ok from auth.users where lower(email) = lower($1)", [body.email ?? "", body.password ?? ""]);
            if (!rows[0]?.ok) return send(res, 400, { code: 400, error_code: "invalid_credentials", msg: "Invalid login credentials", error: "invalid_grant", error_description: "Invalid login credentials" });
            return send(res, 200, session(rows[0]));
          }
          if (grant === "refresh_token") {
            const id = refresh.get(body.refresh_token);
            const { rows } = id ? await getPool().query("select id, email, created_at from auth.users where id = $1", [id]) : { rows: [] };
            if (!rows[0]) return send(res, 400, { code: 400, error_code: "refresh_token_not_found", msg: "Invalid Refresh Token: Refresh Token Not Found" });
            refresh.delete(body.refresh_token);
            return send(res, 200, session(rows[0]));
          }
          return send(res, 400, { code: 400, msg: "unsupported grant" });
        }
        if (route === "user" && req.method === "GET") {
          const pl = verify((req.headers.authorization ?? "").replace(/^Bearer /i, ""), opts.secret);
          if (!pl || pl.role !== "authenticated") return send(res, 401, { code: 401, error_code: "bad_jwt", msg: "invalid JWT" });
          const { rows } = await getPool().query("select id, email, created_at from auth.users where id = $1", [pl.sub]);
          return rows[0] ? send(res, 200, userJson(rows[0])) : send(res, 404, { code: 404, msg: "User not found" });
        }
        if (route === "logout") { res.writeHead(204); return res.end(); }
        return send(res, 404, { code: 404, msg: `not implemented in the test gateway: ${route}` });
      }
      if (url.pathname.startsWith("/rest/v1/")) {
        const body = await readBody(req);
        const headers = { ...req.headers, host: `127.0.0.1:${opts.postgrestPort}` } as http.OutgoingHttpHeaders;
        delete headers["content-length"];
        const up = http.request({ host: "127.0.0.1", port: opts.postgrestPort, method: req.method, path: url.pathname.slice("/rest/v1".length) + url.search, headers: { ...headers, "content-length": Buffer.byteLength(body) } }, (r) => {
          res.writeHead(r.statusCode ?? 502, r.headers);
          const chunks: Buffer[] = [];
          r.on("data", (c) => { chunks.push(c); res.write(c); });
          r.on("end", () => {
            res.end();
            // every database request that failed is written down, so a test can tell what a screen asked for and was refused
            if ((r.statusCode ?? 0) >= 400 && process.env.E2E_REST_LOG) appendFileSync(process.env.E2E_REST_LOG, JSON.stringify({ at: Date.now(), status: r.statusCode, method: req.method, path: decodeURIComponent(url.pathname + url.search).slice(0, 300), error: Buffer.concat(chunks).toString().slice(0, 300) }) + "\n");
          });
        });
        up.on("error", (e) => send(res, 502, { message: String(e) }));
        return void up.end(body);
      }
      send(res, 404, { message: "not found" });
    } catch (e) { send(res, 500, { message: String(e) }); }
  });
  return new Promise<http.Server>((ok) => server.listen(opts.port, "127.0.0.1", () => ok(server)));
}
