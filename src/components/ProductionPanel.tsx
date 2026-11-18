import { createClient } from "@/lib/supabase/server";
import { t, type Locale } from "@/lib/i18n";
import { addStage, setStage, addQualityCheck } from "@/app/production-actions";

// Shows production stages and QC results; action forms appear only where the database would allow them.
export async function ProductionPanel({ locale, caseId, caseStatus }: { locale: Locale; caseId: string; caseStatus: string }) {
  const supabase = await createClient();
  const [{ data: stages }, { data: checks }, { data: canWrite }, { data: canWork }] = await Promise.all([
    supabase.from("production_stages").select("id,name,position,status,started_at,completed_at,notes").eq("case_id", caseId).order("position").order("created_at"),
    supabase.from("quality_checks").select("id,result,notes,created_at").eq("case_id", caseId).order("id", { ascending: false }),
    supabase.rpc("has_permission", { p_code: "cases.write" }),
    supabase.rpc("has_permission", { p_code: "production.work" }),
  ]);
  const mayAct = canWrite === true || canWork === true; // RLS/functions re-check assignment
  const planning = ["approved", "production"].includes(caseStatus);
  const S = (s: string) => t(locale, `ps_${s}` as never);
  if (!["approved", "production", "quality_control"].includes(caseStatus) && (stages ?? []).length === 0 && (checks ?? []).length === 0) return null;
  return (
    <div className="card" style={{ marginTop: "1rem" }}>
      <h2>{t(locale, "production")}</h2>
      <table style={{ width: "100%", borderCollapse: "collapse" }}>
        <thead><tr><th scope="col">{t(locale, "stage")}</th><th scope="col">{t(locale, "status")}</th><th scope="col">{t(locale, "notes")}</th><th scope="col"><span className="sr-only">{t(locale, "moveTo")}</span></th></tr></thead>
        <tbody>{(stages ?? []).map((s) => (
          <tr key={s.id}><td>{s.name}</td><td>{S(s.status)}</td><td>{s.notes ?? ""}</td>
            <td>{mayAct && caseStatus === "production" && s.status !== "completed" && (
              <form action={setStage} style={{ display: "flex", gap: ".5rem" }}>
                <input type="hidden" name="id" value={s.id} /><input type="hidden" name="case_id" value={caseId} />
                <input type="hidden" name="to" value={s.status === "pending" ? "in_progress" : "completed"} />
                <input name="notes" aria-label={t(locale, "notes")} maxLength={2000} />
                <button type="submit">{s.status === "pending" ? t(locale, "startStage") : t(locale, "completeStage")}</button></form>)}</td></tr>))}</tbody>
      </table>
      {(stages ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
      {mayAct && planning && (
        <form action={addStage}>
          <input type="hidden" name="case_id" value={caseId} />
          <label htmlFor="stage_name">{t(locale, "stage")}</label><input id="stage_name" name="name" required maxLength={100} />
          <label htmlFor="stage_pos">#</label><input id="stage_pos" name="position" type="number" min="0" defaultValue={(stages ?? []).length + 1} dir="ltr" />
          <p><button type="submit">{t(locale, "addStage")}</button></p></form>)}
      <h3>{t(locale, "qualityControl")}</h3>
      <ul>{(checks ?? []).map((c) => <li key={c.id}>{t(locale, c.result === "pass" ? "qcPass" : "qcFail")}{c.notes ? ` — ${c.notes}` : ""}</li>)}</ul>
      {mayAct && caseStatus === "quality_control" && (
        <form action={addQualityCheck}>
          <input type="hidden" name="case_id" value={caseId} />
          <label htmlFor="qc_result">{t(locale, "qcResult")}</label>
          <select id="qc_result" name="result"><option value="pass">{t(locale, "qcPass")}</option><option value="fail">{t(locale, "qcFail")}</option></select>
          <label htmlFor="qc_notes">{t(locale, "notes")}</label><input id="qc_notes" name="notes" maxLength={2000} />
          <p><small>{t(locale, "qcFailNeedsNotes")}</small></p>
          <p><button type="submit">{t(locale, "save")}</button></p></form>)}
    </div>
  );
}
