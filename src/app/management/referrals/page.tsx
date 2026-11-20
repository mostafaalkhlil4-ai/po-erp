import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";
import { ReferralForm } from "./ReferralForm";
import { setReferralStatus } from "./actions";

export default async function ReferralsPage() {
  const locale = await getLocale();
  const supabase = await createClient();
  const [{ data: refs }, { data: pts }, { data: docs }, { data: canManage }] = await Promise.all([
    supabase.from("referrals").select("id,patient_id,referring_doctor_id,reason,status,created_at").order("created_at", { ascending: false }).limit(100),
    supabase.from("patients").select("id,full_name,file_no").eq("is_archived", false).order("full_name"),
    supabase.from("doctors").select("id,full_name").order("full_name"),
    supabase.rpc("has_permission", { p_code: "doctors.manage" }),
  ]);
  const pn = new Map((pts ?? []).map((p) => [p.id, p.full_name]));
  const dn = new Map((docs ?? []).map((d) => [d.id, d.full_name]));
  const l = { patient: t(locale, "patients"), doctor: t(locale, "doctors"), reason: t(locale, "notes"), save: t(locale, "save"), saved: t(locale, "saved"),
    err_invalid: t(locale, "invalidInput"), err_forbidden: t(locale, "errForbidden"), err_failed: t(locale, "errFailed") };
  return (
    <Shell locale={locale} role="management">
      <div className="card">
        <h1>{t(locale, "referrals")}</h1>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead><tr><th scope="col">{t(locale, "patients")}</th><th scope="col">{t(locale, "doctors")}</th><th scope="col">{t(locale, "notes")}</th><th scope="col">{t(locale, "status")}</th></tr></thead>
          <tbody>{(refs ?? []).map((r) => (
            <tr key={r.id}><td>{pn.get(r.patient_id) ?? "—"}</td><td>{dn.get(r.referring_doctor_id) ?? "—"}</td><td>{r.reason ?? ""}</td>
              <td>{canManage === true ? (
                <form action={setReferralStatus} style={{ display: "flex", gap: ".25rem" }}>
                  <input type="hidden" name="id" value={r.id} />
                  <select name="status" defaultValue={r.status} aria-label={t(locale, "status")}>{(["received", "accepted", "rejected", "closed"] as const).map((s) => <option key={s} value={s}>{t(locale, `rf_${s}` as never)}</option>)}</select>
                  <button type="submit">{t(locale, "save")}</button></form>) : t(locale, `rf_${r.status}` as never)}</td></tr>))}</tbody>
        </table>
        {(refs ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
      </div>
      {canManage === true && (pts ?? []).length > 0 && (docs ?? []).length > 0 && <div className="card" style={{ marginTop: "1rem" }}><h2>{t(locale, "newReferral")}</h2>
        <ReferralForm l={l} patients={(pts ?? []).map((p) => ({ id: p.id, label: `${p.full_name} #${p.file_no}` }))} doctors={(docs ?? []).map((d) => ({ id: d.id, label: d.full_name }))} /></div>}
    </Shell>
  );
}
