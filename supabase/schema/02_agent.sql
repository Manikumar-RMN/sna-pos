-- =====================================================================
-- SNA POS - Migration 002: The SNA POS Agent
-- Apply AFTER sna_pos_schema_v2.sql
-- Date: 23 Sep 2026
--
-- Adds the tables the AI agent needs, built so that:
--   * every agent action is attributable and tenant-scoped
--   * the agent can PROPOSE a change but never apply one silently
--   * the owner can switch the agent off and cap what it costs
--   * an auditor can tell a human action from an agent action
--
-- The agent itself is NOT given write access to business tables by this
-- migration. See agent-architecture.md, section "Security".
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Tell human actions apart from agent actions in the audit trail.
--    Without this, "who cancelled that bill?" becomes unanswerable the
--    moment an agent exists.
-- ---------------------------------------------------------------------
alter table public.audit_logs
    add column actor_type text not null default 'user'
        check (actor_type in ('user','agent','system')),
    add column agent_session_id uuid;

-- ---------------------------------------------------------------------
-- 2. Per-restaurant agent settings. The agent is OFF until the owner
--    turns it on, and it has a spend ceiling from the first day.
-- ---------------------------------------------------------------------
create table public.agent_settings (
    restaurant_id     uuid        primary key references public.restaurants(id) on delete cascade,
    is_enabled        boolean     not null default false,
    -- Which jobs are allowed. Analyst is read-only and safe; the others
    -- are switched on deliberately.
    allow_analyst     boolean     not null default true,
    allow_back_office boolean     not null default false,
    allow_forecasting boolean     not null default false,
    preferred_language text       not null default 'en',   -- 'en', 'ta', 'hi', 'ar'
    -- Cost control. A runaway loop must not be able to drain the budget.
    monthly_question_cap integer  not null default 500 check (monthly_question_cap >= 0),
    monthly_spend_cap    numeric(14,2) not null default 0 check (monthly_spend_cap >= 0),
    -- Required for the privacy policy: the owner consented to business
    -- data being processed by an AI provider.
    ai_processing_consent_at timestamptz,
    ai_provider_name  text,
    created_at        timestamptz not null default now(),
    updated_at        timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 3. A conversation with the agent.
-- ---------------------------------------------------------------------
create table public.agent_sessions (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    branch_id     uuid        references public.branches(id) on delete set null,
    -- The agent always acts AS a user, never as itself. This is what
    -- keeps Row Level Security meaningful.
    user_id       uuid        not null references public.users(id) on delete restrict,
    channel       text        not null default 'in_app'
                   check (channel in ('in_app','whatsapp','voice')),
    job           text        not null
                   check (job in ('analyst','back_office','forecasting','support')),
    started_at    timestamptz not null default now(),
    ended_at      timestamptz,
    created_at    timestamptz not null default now()
);
create index idx_agent_sessions_restaurant on public.agent_sessions(restaurant_id, started_at desc);
create index idx_agent_sessions_user on public.agent_sessions(user_id);

alter table public.audit_logs
    add constraint audit_logs_agent_session_fk
    foreign key (agent_session_id) references public.agent_sessions(id) on delete set null;

create table public.agent_messages (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    session_id    uuid        not null references public.agent_sessions(id) on delete cascade,
    role          text        not null check (role in ('user','agent','tool')),
    content       text        not null,
    -- What the agent actually ran, so an answer can always be checked
    -- against the data. An unexplainable answer is a useless answer.
    executed_query text,
    rows_returned integer,
    input_tokens  integer,
    output_tokens integer,
    latency_ms    integer,
    created_at    timestamptz not null default now()
);
create index idx_agent_messages_session on public.agent_messages(session_id, created_at);

-- ---------------------------------------------------------------------
-- 4. Proposed actions. The agent writes a row here; a HUMAN approves it;
--    only then does application code apply it. The agent never applies
--    its own proposal.
-- ---------------------------------------------------------------------
create table public.agent_actions (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    session_id    uuid        not null references public.agent_sessions(id) on delete cascade,
    action_type   text        not null,                   -- 'menu.create_item'
    entity_type   text        not null,
    entity_id     uuid,
    proposed_change jsonb     not null,
    rationale     text,
    status        text        not null default 'proposed'
                   check (status in ('proposed','approved','rejected','applied','failed')),
    -- A proposal cannot become 'approved' or 'applied' without a named
    -- human. Enforced by the check below, not by trust.
    reviewed_by   uuid        references public.users(id) on delete set null,
    reviewed_at   timestamptz,
    review_note   text,
    applied_at    timestamptz,
    created_at    timestamptz not null default now(),
    check (status not in ('approved','applied') or reviewed_by is not null)
);
create index idx_agent_actions_pending on public.agent_actions(restaurant_id, status)
    where status = 'proposed';

-- ---------------------------------------------------------------------
-- 5. Usage and cost, per restaurant per month. Needed to enforce the cap
--    and to price the plans on measured numbers rather than guesses.
-- ---------------------------------------------------------------------
create table public.agent_usage (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    period_month  date        not null,                   -- first day of the month
    questions_asked integer   not null default 0,
    input_tokens  bigint      not null default 0,
    output_tokens bigint      not null default 0,
    estimated_cost numeric(14,4) not null default 0,
    currency_code char(3)     not null default 'USD' references public.currencies(code),
    updated_at    timestamptz not null default now(),
    unique (restaurant_id, period_month)
);

-- ---------------------------------------------------------------------
-- 6. New permissions for the agent features.
-- ---------------------------------------------------------------------
insert into public.permissions (key, description, is_sensitive) values
    ('agent.use',            'Ask the SNA POS Agent questions',           false),
    ('agent.approve_action', 'Approve a change the agent proposed',       true),
    ('agent.configure',      'Turn the agent on or off and set its caps', true)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 7. Row Level Security on every new table - same rule as everything
--    else: you only ever see your own restaurant's rows.
-- ---------------------------------------------------------------------
do $$
declare
    t text;
begin
    foreach t in array array[
        'agent_settings','agent_sessions','agent_messages',
        'agent_actions','agent_usage'
    ]
    loop
        execute format('alter table public.%I enable row level security', t);
        execute format('alter table public.%I force row level security', t);
        execute format(
            'create policy tenant_isolation on public.%I
                 for all to authenticated
                 using (restaurant_id = app.current_restaurant_id())
                 with check (restaurant_id = app.current_restaurant_id())',
            t);
    end loop;
end
$$;

-- agent_settings and agent_usage carry updated_at; attach the trigger.
create trigger trg_touch_updated_at before update on public.agent_settings
    for each row execute function app.touch_updated_at();
create trigger trg_touch_updated_at before update on public.agent_usage
    for each row execute function app.touch_updated_at();

-- ---------------------------------------------------------------------
-- 8. The agent's own database role: READ ONLY.
--    This is the rule that stops a prompt-injection attack from
--    changing or deleting anything. The agent service connects as this
--    role using the signed-in user's token - never the service-role key.
-- ---------------------------------------------------------------------
do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'sna_pos_agent') then
        create role sna_pos_agent;
    end if;
end
$$;

grant usage on schema public, app to sna_pos_agent;
grant select on all tables in schema public to sna_pos_agent;
-- The agent may record its own conversation and propose actions. Nothing else.
grant insert on public.agent_sessions, public.agent_messages, public.agent_actions
    to sna_pos_agent;
grant execute on function app.current_restaurant_id() to sna_pos_agent;
grant execute on function app.has_permission(text) to sna_pos_agent;

-- Explicitly deny the agent any write to business data, now and for any
-- table added later.
alter default privileges in schema public
    revoke insert, update, delete on tables from sna_pos_agent;

-- The tenant_isolation policies created in the base schema are granted
-- 'to authenticated'. The agent role is deliberately NOT a member of
-- authenticated - if it were, it would inherit authenticated's write
-- privileges and stop being read-only. So the agent needs its own
-- policies: same tenant rule, SELECT only.
--
-- The result is two independent layers. Even if someone later grants the
-- agent an UPDATE privilege by mistake, there is no policy permitting an
-- agent write, so the write still fails.
do $$
declare
    t record;
begin
    for t in
        select c.relname as table_name
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        join pg_attribute a on a.attrelid = c.oid
        where n.nspname = 'public'
          and c.relkind = 'r'
          and a.attname = 'restaurant_id'
          and not a.attisdropped
        order by c.relname
    loop
        execute format(
            'create policy agent_read on public.%I
                 for select
                 to sna_pos_agent
                 using (restaurant_id = app.current_restaurant_id())',
            t.table_name);
    end loop;
end
$$;

create policy agent_read on public.restaurants
    for select to sna_pos_agent
    using (id = app.current_restaurant_id());

create policy agent_read_reference on public.countries   for select to sna_pos_agent using (true);
create policy agent_read_reference on public.currencies  for select to sna_pos_agent using (true);
create policy agent_read_reference on public.permissions for select to sna_pos_agent using (true);

-- The three tables the agent may append to: its own conversation and its
-- proposals. It can never modify or delete even these.
create policy agent_write_own_session on public.agent_sessions
    for insert to sna_pos_agent
    with check (restaurant_id = app.current_restaurant_id());
create policy agent_write_own_message on public.agent_messages
    for insert to sna_pos_agent
    with check (restaurant_id = app.current_restaurant_id());
create policy agent_write_own_action on public.agent_actions
    for insert to sna_pos_agent
    with check (restaurant_id = app.current_restaurant_id()
                -- An agent proposal always starts unreviewed. The agent
                -- cannot create a pre-approved action for itself.
                and status = 'proposed'
                and reviewed_by is null);

commit;
