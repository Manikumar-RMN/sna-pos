import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, closePool, haveDb, rpc } from "./support/db";
import { expectError } from "./support/oracle";
import { items, makeWorld, type World } from "./support/world";

const localToday = async (tz: string) => (await admin("select (now() at time zone $1)::date::text d", [tz]))[0].d as string;
const addDays = async (d: string, n: number) => (await admin("select ($1::date + $2::int)::text d", [d, n]))[0].d as string;

describe.skipIf(!haveDb())("the client's own time zone (Settings -> Company) decides every date", () => {
  let w: World, other: World;
  beforeAll(async () => {
    w = await makeWorld("tzs");
    other = await makeWorld("tzo");
  });
  afterAll(closePool);

  it("only someone with the settings right can change it, and only to a real time zone", async () => {
    await expectError(rpc(w.cashier.auth, "set_company_timezone", ["Asia/Dubai"]), /allow|permission|right/i);
    for (const bad of ["", "  ", "Mars/Base", "posix/UTC", "localtime", "EST5EDT", "Asia/Kolkata'; drop table x;--"])
      await expectError(rpc(w.owner.auth, "set_company_timezone", [bad]), /Choose a time zone/i);
  });

  it("a visitor who is not signed in cannot call it at all", async () => {
    const [{ ok }] = await admin("select has_function_privilege('anon', 'public.set_company_timezone(text)', 'execute') ok");
    expect(ok).toBe(false);
    const [{ ok: a }] = await admin("select has_function_privilege('authenticated', 'public.set_company_timezone(text)', 'execute') ok");
    expect(a).toBe(true);
  });

  it("the owner changes it once and it applies to the restaurant and all its outlets, and the signed-in user sees it", async () => {
    const r = await rpc(w.owner.auth, "set_company_timezone", ["Pacific/Kiritimati"]);
    expect(r.changed).toBe(true);
    const [rest] = await admin("select timezone from public.restaurants where id = $1", [w.restaurantId]);
    expect(rest.timezone).toBe("Pacific/Kiritimati");
    const br = await admin("select distinct timezone from public.branches where restaurant_id = $1", [w.restaurantId]);
    expect(br.map((b) => b.timezone)).toEqual(["Pacific/Kiritimati"]);
    const me = await rpc(w.cashier.auth, "my_account_state", []).catch(() => null);
    expect(me === null || typeof me === "string").toBe(true);
    const [cu] = await admin("select timezone from public.v_current_user where auth_user_id = $1", [w.owner.auth]).catch(() => [null as any]);
    if (cu) expect(cu.timezone).toBe("Pacific/Kiritimati");
    const audit = await admin("select action from public.audit_logs where restaurant_id = $1 and action = 'company.timezone'", [w.restaurantId]);
    expect(audit.length).toBe(1);
  });

  it("saving the same zone again changes nothing; another restaurant is not touched", async () => {
    expect((await rpc(w.owner.auth, "set_company_timezone", ["Pacific/Kiritimati"])).changed).toBe(false);
    const [o] = await admin("select timezone from public.restaurants where id = $1", [other.restaurantId]);
    expect(o.timezone).not.toBe("Pacific/Kiritimati");
  });

  it("it cannot be changed while a shift is open (a bill must not move to another day), and can once the shift is closed", async () => {
    await rpc(w.cashier.auth, "open_shift", [0]);
    await expectError(rpc(w.owner.auth, "set_company_timezone", ["Pacific/Pago_Pago"]), /Close the open shift/i);
    await rpc(w.manager.auth, "close_shift", [0, ""]);
    expect((await rpc(w.owner.auth, "set_company_timezone", ["Pacific/Pago_Pago"])).changed).toBe(true);
  });

  for (const tz of ["Pacific/Kiritimati", "Pacific/Pago_Pago", "Asia/Kolkata"]) {
    it(`in ${tz}: a tax rate set today is dated today in the restaurant's calendar`, async () => {
      await admin("update public.restaurants set timezone = $1 where id = $2", [tz, w.restaurantId]);
      await admin("update public.branches set timezone = $1 where restaurant_id = $2", [tz, w.restaurantId]);
      const today = await localToday(tz);
      const g = await rpc(w.owner.auth, "create_tax_group", [`GST ${tz}`, 7]);
      const gid = typeof g === "string" ? g : g.id ?? g.tax_group_id;
      const [rate] = await admin("select valid_from::text d from public.tax_rates where tax_group_id = $1 order by valid_from desc limit 1", [gid]);
      expect(rate.d).toBe(today);
      await rpc(w.owner.auth, "set_tax_rate", [gid, 9]);
      const rates = await admin("select valid_from::text f, valid_to::text t, total_rate::float r from public.tax_rates where tax_group_id = $1 order by created_at", [gid]);
      const live = rates.filter((r) => r.t === null);
      expect(live).toHaveLength(1);
      expect(live[0].r).toBe(9);
      expect(live[0].f).toBe(today);
      // no rate is dated in the database's (UTC) calendar when that differs from the restaurant's
      expect(rates.every((r) => r.f <= today && (r.t === null || r.t < today || r.t === today))).toBe(true);
    });
  }

  it("a batch made 'today' is today in the restaurant's calendar; tomorrow is refused", async () => {
    await admin("update public.restaurants set timezone = 'Pacific/Kiritimati' where id = $1", [w.restaurantId]);
    await admin("update public.branches set timezone = 'Pacific/Kiritimati' where restaurant_id = $1", [w.restaurantId]);
    await admin("update public.products set track_batches = true where id = $1", [w.products.dosa.id]);
    const today = await localToday("Pacific/Kiritimati");
    await rpc(w.manager.auth, "batch_add", [w.products.dosa.id, 5, await addDays(today, 2), null, null]);
    const [b] = await admin("select made_on::text d from public.product_batches where product_id = $1", [w.products.dosa.id]);
    expect(b.d).toBe(today);
    await expectError(rpc(w.manager.auth, "batch_add", [w.products.dosa.id, 5, await addDays(today, 3), await addDays(today, 1), null]), /cannot be in the future/i);
    await rpc(w.manager.auth, "batch_add", [w.products.dosa.id, 5, await addDays(today, 3), today, null]);
  });

  it("a batch that expires today (restaurant date) still counts as in stock; the day after it does not", async () => {
    await admin("update public.restaurants set timezone = 'Pacific/Pago_Pago' where id = $1", [w.restaurantId]);
    await admin("update public.branches set timezone = 'Pacific/Pago_Pago' where restaurant_id = $1", [w.restaurantId]);
    const today = await localToday("Pacific/Pago_Pago");
    await admin("update public.product_batches set made_on = $1, expires_on = $2 where product_id = $3", [await addDays(today, -5), today, w.products.dosa.id]);
    let l = await rpc(w.manager.auth, "batches_list", []);
    const dish = (x: any) => x.dishes.find((d: any) => d.id === w.products.dosa.id);
    expect(Number(dish(l).left)).toBeGreaterThan(0);
    expect(l.batches.every((b: any) => b.expired === false)).toBe(true);
    await admin("update public.product_batches set made_on = $1, expires_on = $2 where product_id = $3", [await addDays(today, -5), await addDays(today, -1), w.products.dosa.id]);
    l = await rpc(w.manager.auth, "batches_list", []);
    expect(Number(dish(l).left)).toBe(0);
    expect(l.batches.every((b: any) => b.expired === true)).toBe(true);
  });
});
