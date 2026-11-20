import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";
import { ProductionPanel } from "@/components/ProductionPanel";
import { CaseExtras } from "@/components/CaseExtras";
import { MovementForm } from "@/app/management/inventory/Forms";
import { addMeasurement, addTechAssessment, techAdvance } from "./actions";

export default async function TechCase({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: c } = await supabase.from("cases").select("id,case_no,case_type,status,patient_id").eq("id", id).maybeSingle();
  if (!c) notFound();
  const [{ data: p }, { data: meas }, { data: ass }, { data: next }, { data: stock }] = await Promise.all([
    supabase.from("patients").select("full_name").eq("id", c.patient_id).maybeSingle(),
    supabase.from("measurements").select("id,label,value,unit,side").eq("case_id", id).order("created_at"),
    supabase.from("assessments").select("id,findings,created_at").eq("case_id", id).eq("assessment_type", "technical").order("created_at", { ascending: false }),
    supabase.from("case_transitions").select("to_status").eq("from_status", c.status).eq("actor_kind", "technician"),
    supabase.from("inventory_items").select("id,name,sku,unit").eq("is_active", true).order("name"),
  ]);
  const S = (s: string) => t(locale, `st_${s}` as never);
  const open = !["closed", "cancelled"].includes(c.status);
  return (
    <Shell locale={locale} role="technician">
      <div className="card">
        <h1>#{c.case_no} — {p?.full_name ?? "—"}</h1>
        <p>{c.case_type} · {t(locale, "status")}: <strong>{S(c.status)}</strong></p>
        {(next ?? []).length > 0 && (
          <form action={techAdvance} style={{ display: "flex", gap: ".5rem" }}>
            <input type="hidden" name="case_id" value={c.id} />
            <select name="to" aria-label={t(locale, "moveTo")}>{(next ?? []).map((n) => <option key={n.to_status} value={n.to_status}>{S(n.to_status)}</option>)}</select>
            <input name="note" aria-label={t(locale, "notes")} placeholder={t(locale, "notes")} maxLength={1000} />
            <button type="submit">{t(locale, "moveTo")}</button></form>)}
      </div>
      <ProductionPanel locale={locale} caseId={c.id} caseStatus={c.status} />
      <CaseExtras locale={locale} caseId={c.id} patientId={c.patient_id} caseStatus={c.status} />
      {open && (stock ?? []).length > 0 && <div className="card" style={{ marginTop: "1rem" }}><h2>{t(locale, "issueMaterial")}</h2>
        <MovementForm caseId={c.id} kinds={["issue"]} items={(stock ?? []).map((i) => ({ id: i.id, label: `${i.name} (${i.sku}, ${i.unit})` }))}
          l={{ item: t(locale, "item"), kind: t(locale, "kind"), quantity: t(locale, "quantity"), notes: t(locale, "notes"), mv_issue: t(locale, "mv_issue"),
            save: t(locale, "save"), saved: t(locale, "saved"), err_invalid: t(locale, "invalidInput"), err_forbidden: t(locale, "errForbidden"),
            err_stock: t(locale, "errStockRule"), err_failed: t(locale, "errFailed"), err_duplicate: t(locale, "errFailed"), caseFor: "" }} /></div>}
      <div className="card" style={{ marginTop: "1rem" }}>
        <h2>{t(locale, "measurements")}</h2>
        <ul>{(meas ?? []).map((m) => <li key={m.id}>{m.label}: {m.value} {m.unit}{m.side ? ` (${m.side})` : ""}</li>)}</ul>
        {open && <form action={addMeasurement}>
          <input type="hidden" name="case_id" value={c.id} />
          <label htmlFor="label">{t(locale, "title")}</label><input id="label" name="label" required maxLength={100} />
          <label htmlFor="value">{t(locale, "value")}</label><input id="value" name="value" type="number" step="0.01" required dir="ltr" />
          <label htmlFor="unit">{t(locale, "unit")}</label><select id="unit" name="unit"><option>mm</option><option>cm</option><option>kg</option><option>deg</option></select>
          <label htmlFor="side">{t(locale, "side")}</label><select id="side" name="side"><option value="">—</option><option value="left">left</option><option value="right">right</option></select>
          <p><button type="submit">{t(locale, "save")}</button></p></form>}
      </div>
      <div className="card" style={{ marginTop: "1rem" }}>
        <h2>{t(locale, "technicalAssessments")}</h2>
        <ul>{(ass ?? []).map((a) => <li key={a.id}>{a.findings}</li>)}</ul>
        {open && <form action={addTechAssessment}>
          <input type="hidden" name="case_id" value={c.id} /><input type="hidden" name="patient_id" value={c.patient_id} />
          <label htmlFor="findings">{t(locale, "findings")}</label>
          <textarea id="findings" name="findings" rows={3} required style={{ width: "100%" }} />
          <p><button type="submit">{t(locale, "save")}</button></p></form>}
      </div>
    </Shell>
  );
}
