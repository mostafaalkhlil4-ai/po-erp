import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";
import { CaseForm } from "./CaseForm";

export default async function CasesPage() {
  const locale = await getLocale();
  const supabase = await createClient();
  const [{ data: cases }, { data: patients }, { data: doctors }, { data: canWrite }] = await Promise.all([
    supabase.from("cases").select("id,case_no,case_type,status,priority,patient_id").order("case_no", { ascending: false }).limit(100),
    supabase.from("patients").select("id,file_no,full_name").eq("is_archived", false).order("full_name"),
    supabase.from("doctors").select("id,full_name").eq("is_active", true).order("full_name"),
    supabase.rpc("has_permission", { p_code: "cases.write" }),
  ]);
  const pname = new Map((patients ?? []).map((p) => [p.id, p.full_name]));
  const l = {
    patient: t(locale, "patients"), caseType: t(locale, "caseType"), priority: t(locale, "priority"),
    responsibleDoctor: t(locale, "responsibleDoctor"), prosthetic: t(locale, "prosthetic"), orthotic: t(locale, "orthotic"),
    rehabilitation: t(locale, "rehabilitation"), save: t(locale, "save"),
    err_invalid: t(locale, "invalidInput"), err_forbidden: t(locale, "errForbidden"), err_failed: t(locale, "errFailed"),
  };
  return (
    <Shell locale={locale} role="management">
      <div className="card">
        <h1>{t(locale, "cases")}</h1>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead><tr><th scope="col">#</th><th scope="col">{t(locale, "patients")}</th><th scope="col">{t(locale, "caseType")}</th><th scope="col">{t(locale, "status")}</th><th scope="col">{t(locale, "priority")}</th></tr></thead>
          <tbody>{(cases ?? []).map((c) => (
            <tr key={c.id}><td><a href={`/management/cases/${c.id}`}>{c.case_no}</a></td><td>{pname.get(c.patient_id) ?? "—"}</td>
              <td>{c.case_type}</td><td>{t(locale, `st_${c.status}` as never)}</td><td>{c.priority}</td></tr>))}</tbody>
        </table>
        {(cases ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
      </div>
      {canWrite === true && (patients ?? []).length > 0 && (
        <div className="card" style={{ marginTop: "1rem" }}><h2>{t(locale, "newCase")}</h2>
          <CaseForm l={l} patients={(patients ?? []).map((p) => ({ id: p.id, label: `${p.full_name} #${p.file_no}` }))}
            doctors={(doctors ?? []).map((d) => ({ id: d.id, label: d.full_name }))} /></div>)}
    </Shell>
  );
}
