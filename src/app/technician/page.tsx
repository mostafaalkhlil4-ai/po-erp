import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";

export default async function TechnicianHome() {
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: cases } = await supabase.from("cases").select("id,case_no,case_type,status,priority,patient_id").order("case_no", { ascending: false });
  const { data: patients } = await supabase.from("patients").select("id,full_name");
  const pname = new Map((patients ?? []).map((p) => [p.id, p.full_name]));
  return (
    <Shell locale={locale} role="technician">
      <div className="card">
        <h1>{t(locale, "myCases")}</h1>
        <ul>{(cases ?? []).map((c) => <li key={c.id}><a href={`/technician/cases/${c.id}`}>#{c.case_no} {pname.get(c.patient_id) ?? ""}</a> — {c.case_type} — {t(locale, `st_${c.status}` as never)} ({c.priority})</li>)}</ul>
        {(cases ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
      </div>
    </Shell>
  );
}
