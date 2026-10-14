import { admin, adminAs, uuid } from "./db";

export const PASSWORD = "Test-Passw0rd!";
export type Person = { auth: string; userId: string; email: string; code: string };
export type World = {
  tag: string;
  clientCode: string;
  restaurantId: string;
  branchId: string;
  owner: Person;
  manager: Person;
  cashier: Person;
  roles: Record<string, string>;
  taxGroups: Record<string, string>;
  methods: Record<string, string>; // by kind: cash, upi, card ...
  products: Record<string, { id: string; price: number; tax: string }>;
  tableId: string;
};

/** A fresh restaurant (India, GST) with an owner, a manager and a cashier, a small menu and a table. Each test group builds its own. */
export async function makeWorld(tag: string): Promise<World> {
  const people = { owner: uuid(), manager: uuid(), cashier: uuid() };
  for (const [k, id] of Object.entries(people))
    await admin("insert into auth.users (id, email, encrypted_password) values ($1, $2, extensions.crypt($3, extensions.gen_salt('bf')))", [id, `${k}.${tag}@e2e.test`, PASSWORD]);

  // the SNA console (service role) sets the restaurant up for its owner, through the real function
  const [{ v: restaurantId }] = await adminAs<{ v: string }>(people.owner, "select public.create_restaurant_with_owner($1,$2,$3,$4,$5,$6) as v", [`${tag} Foods Pvt Ltd`, `${tag} Kitchen`, "IN", `Owner ${tag}`, "Main", "MN"]);
  const [{ id: branchId }] = await admin<{ id: string }>("select id from public.branches where restaurant_id = $1", [restaurantId]);
  const roles = Object.fromEntries((await admin<{ name: string; id: string }>("select name, id from public.roles where restaurant_id = $1", [restaurantId])).map((r) => [r.name, r.id]));
  const [{ id: ownerUser }] = await admin<{ id: string }>("select id from public.users where auth_user_id = $1", [people.owner]);

  async function addStaff(auth: string, code: string, name: string, role: string, email: string) {
    const [{ id }] = await admin<{ id: string }>(
      "insert into public.users (restaurant_id, auth_user_id, employee_code, full_name, role_id, email) values ($1,$2,$3,$4,$5,$6) returning id",
      [restaurantId, auth, code, name, roles[role], email]);
    await admin("insert into public.user_branches (user_id, branch_id, restaurant_id) values ($1,$2,$3)", [id, branchId, restaurantId]);
    return id;
  }
  const managerUser = await addStaff(people.manager, "EMP002", `Manager ${tag}`, "Manager", `manager.${tag}@e2e.test`);
  const cashierUser = await addStaff(people.cashier, "EMP003", `Cashier ${tag}`, "Cashier", `cashier.${tag}@e2e.test`);

  const [{ client_code: clientCode }] = await admin<{ client_code: string }>("select client_code from public.restaurants where id = $1", [restaurantId]);
  const taxGroups = Object.fromEntries((await admin<{ id: string; name: string }>("select id, name from public.tax_groups where restaurant_id = $1", [restaurantId])).map((g) => [g.name, g.id]));
  const methods: Record<string, string> = {};
  for (const m of await admin<{ id: string; kind: string }>("select id, kind from public.payment_methods where restaurant_id = $1 and is_active order by display_order", [restaurantId]))
    methods[m.kind] ??= m.id;

  const [{ id: cat }] = await admin<{ id: string }>("insert into public.categories (restaurant_id, name, display_order) values ($1,'Mains',1) returning id", [restaurantId]);
  const gst5 = Object.keys(taxGroups).find((n) => /5\s*%/.test(n) && !/12|18/.test(n)) ?? Object.keys(taxGroups)[0];
  const gst18 = Object.keys(taxGroups).find((n) => /18\s*%/.test(n)) ?? gst5;
  const products: World["products"] = {};
  for (const [key, name, price, tg] of [["dosa", "Masala Dosa", 120, gst5], ["biryani", "Chicken Biryani", 249.5, gst5], ["cola", "Cola", 60, gst18], ["thali", "Veg Thali", 333.33, gst5]] as const) {
    const [{ id }] = await admin<{ id: string }>("insert into public.products (restaurant_id, category_id, tax_group_id, name, price) values ($1,$2,$3,$4,$5) returning id", [restaurantId, cat, taxGroups[tg], name, price]);
    products[key] = { id, price, tax: tg };
  }
  const [{ id: tableId }] = await admin<{ id: string }>("insert into public.dining_tables (restaurant_id, branch_id, table_number, seats) values ($1,$2,'T1',4) returning id", [restaurantId, branchId]);

  return {
    tag, clientCode, restaurantId, branchId, roles, taxGroups, methods, products, tableId,
    owner: { auth: people.owner, userId: ownerUser, email: `owner.${tag}@e2e.test`, code: "EMP001" },
    manager: { auth: people.manager, userId: managerUser, email: `manager.${tag}@e2e.test`, code: "EMP002" },
    cashier: { auth: people.cashier, userId: cashierUser, email: `cashier.${tag}@e2e.test`, code: "EMP003" },
  };
}

export const items = (w: World, spec: Record<string, number>) => Object.entries(spec).map(([k, qty]) => ({ product_id: w.products[k].id, qty }));
