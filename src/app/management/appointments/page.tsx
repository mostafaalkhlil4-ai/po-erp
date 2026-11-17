import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";
import { ApptForm } from "./ApptForm";
import { setAppointmentStatus } from "./actions";

export default async function AppointmentsPage() {
  const locale = await getLocale();
  const supabase = await createClient();
  const [{ data: appts }, { data: patients }, { data: cases }, { data: canWrite }] = await Promise.all([
    supabase.from("appointments").select("id,patient_id,case_id,appointment_type,scheduled_at,status").order("scheduled_at", { ascending: false }).limit(100),
    supabase.from("patients").select("id,full_name,file_no").eq("is_archived", false).order("full_name"),
    supabase.from("cases").select("id,case_no,patient_id").not("status", "in", "(closed,cancelled)").order("case_no", { ascending: false }),
    supabase.rpc("has_permission", { p_code: "cases.write" }),
  ]);
  const pname = new Map((patients ?? []).map((p) => [p.id, p.full_name]));
  const l = {
    patient: t(locale, "patients"), case: t(locale, "cases"), type: t(locale, "caseType"), when: t(locale, "when"), notes: t(locale, "notes"),
    save: t(locale, "save"), saved: t(locale, "saved"),
    err_invalid: t(locale, "invalidInput"), err_forbidden: t(locale, "errForbidden"), err_failed: t(locale, "errFailed"),
    ap_assessment: t(locale, "ap_assessment"), ap_fitting: t(locale, "ap_fitting"), ap_follow_up: t(locale, "ap_follow_up"),
    ap_consultation: t(locale, "ap_consultation"), ap_other: t(locale, "ap_other"),
  };
  return (
    <Shell locale={locale} role="management">
      <div className="card">
        <h1>{t(locale, "appointments")}</h1>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead><tr><th scope="col">{t(locale, "when")}</th><th scope="col">{t(locale, "patients")}</th><th scope="col">{t(locale, "caseType")}</th><th scope="col">{t(locale, "status")}</th><th scope="col"><span className="sr-only">{t(locale, "save")}</span></th></tr></thead>
          <tbody>{(appts ?? []).map((a) => (
            <tr key={a.id}>
              <td dir="ltr">{new Date(a.scheduled_at).toISOString().slice(0, 16).replace("T", " ")}</td>
              <td>{pname.get(a.patient_id) ?? "—"}</td><td>{t(locale, `ap_${a.appointment_type}` as never)}</td>
              <td>{t(locale, `apst_${a.status}` as never)}</td>
              <td>{canWrite === true && a.status === "scheduled" && (["completed", "cancelled", "no_show"] as const).map((st) => (
                <form key={st} action={setAppointmentStatus} style={{ display: "inline" }}>
                  <input type="hidden" name="id" value={a.id} /><input type="hidden" name="status" value={st} />
                  <button className="link" type="submit">{t(locale, `apst_${st}` as never)}</button>{" "}
                </form>))}</td>
            </tr>))}</tbody>
        </table>
        {(appts ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
      </div>
      {canWrite === true && (patients ?? []).length > 0 && (
        <div className="card" style={{ marginTop: "1rem" }}><h2>{t(locale, "newAppointment")}</h2>
          <ApptForm l={l} patients={(patients ?? []).map((p) => ({ id: p.id, label: `${p.full_name} #${p.file_no}` }))}
            cases={(cases ?? []).map((c) => ({ id: c.id, label: `#${c.case_no} — ${pname.get(c.patient_id) ?? ""}` }))} /></div>)}
    </Shell>
  );
}
