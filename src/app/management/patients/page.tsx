import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t, type Locale } from "@/lib/i18n";
import { Shell } from "@/components/Shell";
import { PatientForm } from "./PatientForm";

export const patientLabels = (l: Locale) => ({
  fullName: t(l, "fullName"), dob: t(l, "dob"), sex: t(l, "sex"), male: t(l, "male"), female: t(l, "female"),
  phone: t(l, "phone"), email: t(l, "email"), address: t(l, "address"), save: t(l, "save"),
  err_invalid: t(l, "invalidInput"), err_forbidden: t(l, "errForbidden"),
  err_duplicate: t(l, "errDuplicatePatient"), err_failed: t(l, "errFailed"),
});

export default async function PatientsPage({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  const locale = await getLocale();
  const { q } = await searchParams;
  const supabase = await createClient();
  let query = supabase.from("patients").select("id,file_no,full_name,phone,is_archived").order("file_no", { ascending: false }).limit(100);
  const term = (q ?? "").trim().slice(0, 100).replace(/[%_,()]/g, " ");
  if (term) query = query.or(`full_name.ilike.%${term}%,phone.ilike.%${term}%`);
  const { data: rows } = await query;
  const { data: canWrite } = await supabase.rpc("has_permission", { p_code: "patients.write" });

  return (
    <Shell locale={locale}>
      <div className="card">
        <h1>{t(locale, "patients")}</h1>
        <form method="get" role="search" style={{ display: "flex", gap: ".5rem" }}>
          <input name="q" defaultValue={term} aria-label={t(locale, "search")} placeholder={t(locale, "search")} />
          <button type="submit">{t(locale, "search")}</button>
        </form>
        <table style={{ width: "100%", borderCollapse: "collapse", marginTop: "1rem" }}>
          <thead><tr>
            <th scope="col">#</th><th scope="col">{t(locale, "fullName")}</th><th scope="col">{t(locale, "phone")}</th>
          </tr></thead>
          <tbody>{(rows ?? []).map((p) => (
            <tr key={p.id}>
              <td>{p.file_no}</td>
              <td><a href={`/management/patients/${p.id}`}>{p.full_name}</a></td>
              <td dir="ltr">{p.phone}</td>
            </tr>
          ))}</tbody>
        </table>
        {(rows ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
      </div>
      {canWrite === true && (
        <div className="card" style={{ marginTop: "1rem" }}>
          <h2>{t(locale, "newPatient")}</h2>
          <PatientForm l={patientLabels(locale)} />
        </div>
      )}
    </Shell>
  );
}
