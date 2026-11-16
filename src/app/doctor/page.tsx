import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";

export default async function DoctorHome() {
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: rows } = await supabase.from("patients").select("id,file_no,full_name").order("file_no", { ascending: false }).limit(200);
  return (
    <Shell locale={locale} role="doctor">
      <div className="card">
        <h1>{t(locale, "myPatients")}</h1>
        <ul>{(rows ?? []).map((p) => <li key={p.id}><a href={`/doctor/patients/${p.id}`}>{p.full_name}</a> <small>#{p.file_no}</small></li>)}</ul>
        {(rows ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
      </div>
    </Shell>
  );
}
