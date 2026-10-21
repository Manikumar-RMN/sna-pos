import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import { NoAccess, SectionHead } from "../section-head";
import { ReportSchedules, type EmailMode, type Schedule } from "./report-schedules";

type ListInfo = { cutoff?: string; timezone?: string; phone_alert_available?: boolean; schedules?: Omit<Schedule, "unconfirmed">[] };

/** Settings → Daily summary: when the day's figures are sent, and to whom. */
export default async function ReportSettings() {
  const user = await requireUser();
  if (!can(user, "settings.manage") || !can(user, "report.view_sales")) return <NoAccess />;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("report_schedules_list");
  const info = (data ?? {}) as ListInfo;
  // Email needs the email service key on the server. With the key but no sending address of our own, the
  // service is in its trial mode and only delivers to the address the email account was opened with.
  const emailMode: EmailMode = !process.env.RESEND_API_KEY || !process.env.PUSH_SECRET ? "off" : process.env.REPORT_EMAIL_FROM ? "on" : "trial";
  // An email handed over more than two minutes ago with no word back: say so rather than "on its way" for ever.
  const now = Date.now();
  const schedules = (Array.isArray(info.schedules) ? info.schedules : []).map((s) => ({
    ...s,
    unconfirmed:
      !s.last_email_result && (s.last_result ?? "").toLowerCase().includes("on its way") && !!s.last_sent_at && now - Date.parse(s.last_sent_at) > 120_000,
  }));

  return (
    <div className="space-y-4">
      <SectionHead title="Daily summary">
        Send the day&rsquo;s figures by themselves, at a time you choose, to the people you choose: bills, total billed, money received by
        payment method, what is not yet paid and the top dishes.
      </SectionHead>
      {error ? (
        <div className="card p-4 text-sm font-semibold" role="alert" style={{ color: "var(--color-bad)" }}>
          {friendlyDbError(error)}
        </div>
      ) : (
        <ReportSchedules
          schedules={schedules}
          cutoff={/^\d{2}:\d{2}$/.test(info.cutoff ?? "") ? (info.cutoff as string) : "04:00"}
          timezone={info.timezone || user.timezone}
          phoneAlertAvailable={info.phone_alert_available === true}
          emailMode={emailMode}
          outletName={user.outlet_count > 1 ? user.branch_name : null}
        />
      )}
    </div>
  );
}
