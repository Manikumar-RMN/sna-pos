-- 088: remove tables that do not belong to SNA POS
--
-- On 7 Oct 2026 a schema for a separate real-estate "AI employee" project
-- (migration "ai_employee_mvp_schema") was applied to the SNA POS production
-- database by mistake. It is not part of SNA POS and nothing in SNA POS uses it:
-- no function, view or SNA table refers to these tables. Its 8 demo rows were
-- saved first to COMPANY/_claude_tmp/ai-employee-backup-2026-10-12.json.
-- Founder's decision (12 Oct 2026): "remove it".
--
-- The record of that migration is kept in the history, so it shows what happened.
-- The pgcrypto extension it asked for was already there for SNA POS and stays.

begin;
drop table public.appointments, public.interactions, public.knowledge_items, public.properties,
           public.leads, public.ai_employees, public.businesses;
commit;
