import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";
import { countBy } from "@/lib/report";

// Real data: technician accounts and their case assignments, under RLS (staff only).
export default async function TechniciansPage() {
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: allowed } = await supabase.rpc("has_permission", { p_code: "cases.write" });
  if (allowed !== true) redirect("/dashboard");
  const [{ data: techs }, { data: assigns }] = await Promise.all([
    supabase.from("profiles").select("id,email,full_name,is_active").eq("role", "technician").order("email"),
    supabase.from("case_assignments").select("technician_id,ended_at").limit(50000),
  ]);
  const active = countBy((assigns ?? []).filter((a) => !a.ended_at), (a) => a.technician_id);
  const past = countBy((assigns ?? []).filter((a) => a.ended_at), (a) => a.technician_id);
  return (
    <Shell locale={locale} role="admin">
      <div className="card">
        <h1>{t(locale, "technicians")}</h1>
        {(techs ?? []).length === 0 ? <p>{t(locale, "gm_techNone")}</p> : (
          <table>
            <thead><tr><th scope="col">{t(locale, "technicians")}</th><th scope="col">{t(locale, "gm_techActive")}</th><th scope="col">{t(locale, "gm_techPast")}</th><th scope="col">{t(locale, "status")}</th></tr></thead>
            <tbody>{(techs ?? []).map((x) => (
              <tr key={x.id}><td dir="ltr">{x.full_name || x.email}<br /><small>{x.email}</small></td>
                <td className="num" dir="ltr">{active[x.id] ?? 0}</td><td className="num" dir="ltr">{past[x.id] ?? 0}</td>
                <td>{t(locale, x.is_active ? "active" : "inactive")}</td></tr>))}</tbody>
          </table>
        )}
        <p><small>{t(locale, "gm_techNote")}</small></p>
      </div>
    </Shell>
  );
}
