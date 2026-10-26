import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { todayIn } from "@/lib/format";
import { PAGE_SIZE, firstParam, parseCustomerList, parseFilter, parsePage, parseSort, searchText } from "@/lib/customers";
import { friendlyDbError } from "@/lib/db-error";
import { CustomersTable } from "./customers-table";

/** Guest list: who comes, how often, how much they spend, how many points they hold. Visits and spend come from paid bills. */
export default async function CustomersPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const user = await requireUser();
  if (!can(user, "customer.view") && !can(user, "customer.manage")) {
    return <p className="card mx-auto mt-4 max-w-md p-5 text-sm">Your role cannot open the guest list. Ask an owner or manager.</p>;
  }
  const sp = await searchParams;
  const q = firstParam(sp.q).slice(0, 60);
  const filter = parseFilter(firstParam(sp.filter));
  const sort = parseSort(firstParam(sp.sort));
  const page = parsePage(firstParam(sp.page));

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("customer_list", {
    p_q: searchText(q) || undefined,
    p_filter: filter,
    p_sort: sort,
    p_limit: PAGE_SIZE,
    p_offset: (page - 1) * PAGE_SIZE,
  });
  const list = parseCustomerList(data);

  return (
    <CustomersTable
      rows={list.rows}
      total={list.total}
      q={q}
      filter={filter}
      sort={sort}
      page={page}
      today={todayIn(user.timezone)}
      currency={user.currency_code}
      canExport={can(user, "customer.export")}
      showPoints={has(user, "loyalty")}
      error={error ? friendlyDbError(error) : null}
    />
  );
}
