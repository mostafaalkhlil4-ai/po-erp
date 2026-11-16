import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";
import { DoctorForm } from "./DoctorForm";
import { linkDoctorAccount } from "../accounts";

export default async function DoctorsPage() {
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: rows } = await supabase.from("doctors").select("id,full_name,specialty,license_no,is_active,user_id").order("full_name");
  const { data: canManage } = await supabase.rpc("has_permission", { p_code: "doctors.manage" });
  const { data: accounts } = canManage === true
    ? await supabase.from("profiles").select("id,email").eq("role", "doctor").eq("is_active", true).order("email")
    : { data: [] };
  const used = new Set((rows ?? []).map((d) => d.user_id).filter(Boolean));
  const l = {
    fullName: t(locale, "fullName"), specialty: t(locale, "specialty"), licenseNo: t(locale, "licenseNo"),
    phone: t(locale, "phone"), save: t(locale, "save"), saved: t(locale, "saved"),
    err_invalid: t(locale, "invalidInput"), err_forbidden: t(locale, "errForbidden"), err_failed: t(locale, "errFailed"),
  };
  return (
    <Shell locale={locale}>
      <div className="card">
        <h1>{t(locale, "doctors")}</h1>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead><tr><th scope="col">{t(locale, "fullName")}</th><th scope="col">{t(locale, "specialty")}</th><th scope="col">{t(locale, "status")}</th>{canManage === true && <th scope="col">{t(locale, "portalAccount")}</th>}</tr></thead>
          <tbody>{(rows ?? []).map((d) => (
            <tr key={d.id}><td>{d.full_name}</td><td>{d.specialty ?? "—"}</td><td>{t(locale, d.is_active ? "active" : "inactive")}</td>
              {canManage === true && (<td>
                <form action={linkDoctorAccount} style={{ display: "flex", gap: ".5rem" }}>
                  <input type="hidden" name="id" value={d.id} />
                  <select name="user_id" defaultValue={d.user_id ?? ""} aria-label={t(locale, "portalAccount")}>
                    <option value="">—</option>
                    {(accounts ?? []).filter((a) => !used.has(a.id) || a.id === d.user_id).map((a) => <option key={a.id} value={a.id}>{a.email}</option>)}
                  </select>
                  <button type="submit">{t(locale, "save")}</button>
                </form></td>)}
            </tr>))}</tbody>
        </table>
        {(rows ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
      </div>
      {canManage === true && (<div className="card" style={{ marginTop: "1rem" }}><h2>{t(locale, "newDoctor")}</h2><DoctorForm l={l} /></div>)}
    </Shell>
  );
}
