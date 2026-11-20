import { createClient } from "@/lib/supabase/server";
import { t, type Locale } from "@/lib/i18n";
import { addDevice, addComponent, addFollowUp, updateFollowUp } from "@/app/case-actions";
import { UploadForm } from "./UploadForm";

// Devices, follow-ups and attachments of a case. Forms are offered by role/status; RLS decides the rest.
export async function CaseExtras({ locale, caseId, patientId, caseStatus }: { locale: Locale; caseId: string; patientId: string; caseStatus: string }) {
  const supabase = await createClient();
  const [{ data: devices }, { data: comps }, { data: fus }, { data: atts }, { data: canWrite }, { data: canWork }] = await Promise.all([
    supabase.from("devices").select("id,device_type,side,description").eq("case_id", caseId).order("created_at"),
    supabase.from("device_components").select("id,device_id,name,notes").order("created_at"),
    supabase.from("follow_ups").select("id,due_date,status,technical_feedback,device_issues").eq("case_id", caseId).order("due_date"),
    supabase.from("attachments").select("id,file_name,category,visibility,created_at").eq("case_id", caseId).order("created_at", { ascending: false }),
    supabase.rpc("has_permission", { p_code: "cases.write" }),
    supabase.rpc("has_permission", { p_code: "production.work" }),
  ]);
  const mayAct = canWrite === true || canWork === true;
  const open = !["closed", "cancelled"].includes(caseStatus);
  const afterDelivery = ["delivered", "follow_up"].includes(caseStatus);
  const ids = new Set((devices ?? []).map((d) => d.id));
  const l = {
    file: t(locale, "file"), category: t(locale, "category"), visibility: t(locale, "visibility"), upload: t(locale, "upload"),
    photo: t(locale, "cat_photo"), document: t(locale, "cat_document"), design: t(locale, "cat_design"), report: t(locale, "cat_report"), other: t(locale, "cat_other"),
    internal: t(locale, "vis_internal"), shared: t(locale, "vis_shared"), saved: t(locale, "saved"),
    err_invalid: t(locale, "invalidInput"), err_forbidden: t(locale, "errForbidden"), err_failed: t(locale, "errFailed"), err_file: t(locale, "errFile"),
  };
  return (<>
    <div className="card" style={{ marginTop: "1rem" }}>
      <h2>{t(locale, "devices")}</h2>
      <ul>{(devices ?? []).map((d) => (
        <li key={d.id}><strong>{d.device_type}</strong>{d.side ? ` (${d.side})` : ""}{d.description ? ` — ${d.description}` : ""}
          <ul>{(comps ?? []).filter((c) => c.device_id === d.id && ids.has(c.device_id)).map((c) => <li key={c.id}>{c.name}{c.notes ? ` — ${c.notes}` : ""}</li>)}</ul>
          {mayAct && open && <form action={addComponent} style={{ display: "flex", gap: ".5rem" }}>
            <input type="hidden" name="device_id" value={d.id} /><input type="hidden" name="case_id" value={caseId} /><input type="hidden" name="notes" value="" />
            <input name="name" required maxLength={200} aria-label={t(locale, "component")} placeholder={t(locale, "component")} />
            <button type="submit">{t(locale, "add")}</button></form>}
        </li>))}</ul>
      {(devices ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
      {mayAct && open && <form action={addDevice}>
        <input type="hidden" name="case_id" value={caseId} />
        <label htmlFor="device_type">{t(locale, "caseType")}</label><input id="device_type" name="device_type" required maxLength={200} />
        <label htmlFor="dside">{t(locale, "side")}</label><select id="dside" name="side"><option value="">—</option><option value="left">left</option><option value="right">right</option><option value="both">both</option></select>
        <label htmlFor="ddesc">{t(locale, "details")}</label><input id="ddesc" name="description" maxLength={2000} />
        <p><button type="submit">{t(locale, "addDevice")}</button></p></form>}
    </div>
    {(afterDelivery || (fus ?? []).length > 0) && <div className="card" style={{ marginTop: "1rem" }}>
      <h2>{t(locale, "followUps")}</h2>
      {(fus ?? []).map((f) => (
        <form key={f.id} action={updateFollowUp} style={{ borderBottom: "1px solid #e2e8f0", paddingBottom: ".5rem", marginBottom: ".5rem" }}>
          <input type="hidden" name="id" value={f.id} /><input type="hidden" name="case_id" value={caseId} />
          <p><span dir="ltr">{f.due_date}</span> — {t(locale, `fu_${f.status}` as never)}</p>
          {mayAct ? (<>
            <label htmlFor={`fb${f.id}`}>{t(locale, "feedback")}</label><input id={`fb${f.id}`} name="technical_feedback" defaultValue={f.technical_feedback ?? ""} maxLength={5000} />
            <label htmlFor={`di${f.id}`}>{t(locale, "deviceIssues")}</label><input id={`di${f.id}`} name="device_issues" defaultValue={f.device_issues ?? ""} maxLength={5000} />
            <label htmlFor={`st${f.id}`}>{t(locale, "status")}</label>
            <select id={`st${f.id}`} name="status" defaultValue={f.status}><option value="planned">{t(locale, "fu_planned")}</option><option value="done">{t(locale, "fu_done")}</option><option value="cancelled">{t(locale, "fu_cancelled")}</option></select>
            <p><button type="submit">{t(locale, "save")}</button></p></>) : <p>{f.technical_feedback} {f.device_issues}</p>}
        </form>))}
      {mayAct && afterDelivery && <form action={addFollowUp}><input type="hidden" name="case_id" value={caseId} />
        <label htmlFor="due_date">{t(locale, "date")}</label><input id="due_date" name="due_date" type="date" required dir="ltr" />
        <p><button type="submit">{t(locale, "addFollowUp")}</button></p></form>}
    </div>}
    <div className="card" style={{ marginTop: "1rem" }}>
      <h2>{t(locale, "attachments")}</h2>
      <ul>{(atts ?? []).map((a) => <li key={a.id}><a href={`/files/${a.id}`}>{a.file_name}</a> — {t(locale, `cat_${a.category}` as never)} · {t(locale, `vis_${a.visibility}` as never)}</li>)}</ul>
      {(atts ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
      {mayAct && open && <UploadForm patientId={patientId} caseId={caseId} l={l} />}
    </div>
  </>);
}
