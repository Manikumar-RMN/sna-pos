-- 082: the timer for scheduled summaries
--
-- Every 5 minutes the database looks for summaries that are due (081).
-- Scheduling under the same name again replaces the job, so this is safe to repeat.
create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule('sna-report-schedules', '*/5 * * * *', 'select app.run_report_schedules()');
-- The timer keeps a line for every run. A week of them is plenty; tidy up once a night (03:00 in India).
select cron.schedule('sna-timer-history', '30 21 * * *', 'delete from cron.job_run_details where end_time < now() - interval ''7 days''');
