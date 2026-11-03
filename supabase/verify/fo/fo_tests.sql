\set ON_ERROR_STOP on
create schema if not exists t;
create table if not exists t.results(id serial, label text, passed boolean, detail text);

create or replace function t.ok(p_label text, p_cond boolean, p_detail text default null) returns void
language plpgsql as $$
begin insert into t.results(label, passed, detail) values (p_label, coalesce(p_cond,false), p_detail); end $$;

-- Runs p_sql and expects it to raise an error whose message contains p_expect.
create or replace function t.must_fail(p_label text, p_sql text, p_expect text) returns void
language plpgsql as $$
declare v_msg text;
begin
  begin
    execute p_sql;
    insert into t.results(label, passed, detail) values (p_label, false, 'no error raised');
    return;
  exception when others then v_msg := SQLERRM;
  end;
  insert into t.results(label, passed, detail)
  values (p_label, position(lower(p_expect) in lower(v_msg)) > 0, v_msg);
end $$;

-- Runs p_sql and expects it to succeed.
create or replace function t.must_pass(p_label text, p_sql text) returns void
language plpgsql as $$
begin
  begin execute p_sql; insert into t.results(label, passed, detail) values (p_label, true, null);
  exception when others then insert into t.results(label, passed, detail) values (p_label, false, SQLERRM);
  end;
end $$;

-- The business calls run as `authenticated`; the harness must be reachable from there.
grant usage on schema t to authenticated;
grant insert, select on t.results to authenticated;
grant usage, select on sequence t.results_id_seq to authenticated;
grant execute on function t.ok(text, boolean, text), t.must_fail(text, text, text), t.must_pass(text, text) to authenticated;

-- TEST HARNESS ONLY. The product does not grant these to `authenticated` (they are internal helpers); the tests call
-- them to read a balance or the business date without going through a screen. Nothing in the migrations grants them.
grant execute on function app.business_today(uuid) to authenticated;
grant execute on function app.fo_balance(uuid) to authenticated;
