import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";

// Patients only ever receive published reports of their own record (RLS).
export default async function PatientHome() {
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: reps } = await supabase.from("shareable_reports")
    .select("id,title,body,published_at").eq("status", "published").order("published_at", { ascending: false });
  return (
    <Shell locale={locale} role="patient">
      <div className="card">
        <h1>{t(locale, "myReports")}</h1>
        {(reps ?? []).map((r) => (
          <article key={r.id} style={{ marginBottom: "1.5rem" }}>
            <h2>{r.title}</h2>
            <p style={{ whiteSpace: "pre-wrap" }}>{r.body}</p>
            <small>{r.published_at ? new Date(r.published_at).toISOString().slice(0, 10) : ""}</small>
          </article>))}
        {(reps ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
      </div>
    </Shell>
  );
}
