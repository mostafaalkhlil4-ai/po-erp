import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";
import { advanceCase, assignTechnician, unassignTechnician } from "../actions";
import { QuotationForm } from "../../quotations/QuotationForm";

export default async function CaseDetail({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: c } = await supabase.from("cases").select("id,case_no,case_type,status,priority,patient_id,opened_at,closed_at").eq("id", id).maybeSingle();
  if (!c) notFound();
  const [{ data: patient }, { data: next }, { data: asg }, { data: techs }, { data: events }, { data: meas }, { data: canWrite }, { data: quotes }, { data: canQuote }] = await Promise.all([
    supabase.from("patients").select("full_name").eq("id", c.patient_id).maybeSingle(),
    supabase.from("case_transitions").select("to_status").eq("from_status", c.status).eq("actor_kind", "staff"),
    supabase.from("case_assignments").select("id,technician_id").eq("case_id", id).is("ended_at", null),
    supabase.from("profiles").select("id,email,full_name").eq("role", "technician").eq("is_active", true).order("email"),
    supabase.from("case_events").select("id,event_type,from_status,to_status,note,created_at").eq("case_id", id).order("id"),
    supabase.from("measurements").select("id,label,value,unit,side,created_at").eq("case_id", id).order("created_at"),
    supabase.rpc("has_permission", { p_code: "cases.write" }),
    supabase.from("quotations").select("id,quotation_no,revision,status,currency").eq("case_id", id).order("quotation_no"),
    supabase.rpc("has_permission", { p_code: "quotations.manage" }),
  ]);
  const w = canWrite === true;
  // quotation -> approved is blocked by the database until the quotation module exists: do not offer a dead option.
  const nextOptions = (next ?? []).filter((n) => !(c.status === "quotation" && n.to_status === "approved"));
  const tname = new Map((techs ?? []).map((x) => [x.id, x.full_name || x.email]));
  const assigned = new Set((asg ?? []).map((a) => a.technician_id));
  const S = (s: string) => t(locale, `st_${s}` as never);

  return (
    <Shell locale={locale} role="management">
      <div className="card">
        <h1>#{c.case_no} — {patient?.full_name ?? "—"}</h1>
        <p>{t(locale, "caseType")}: {c.case_type} · {t(locale, "priority")}: {c.priority} · {t(locale, "status")}: <strong>{S(c.status)}</strong></p>
        {w && nextOptions.length > 0 && (
          <form action={advanceCase} style={{ display: "flex", gap: ".5rem", flexWrap: "wrap" }}>
            <input type="hidden" name="case_id" value={c.id} />
            <select name="to" aria-label={t(locale, "moveTo")}>{nextOptions.map((n) => <option key={n.to_status} value={n.to_status}>{S(n.to_status)}</option>)}</select>
            <input name="note" aria-label={t(locale, "notes")} placeholder={t(locale, "notes")} maxLength={1000} />
            <button type="submit">{t(locale, "moveTo")}</button>
          </form>)}
        {c.status === "quotation" && <p><small>{t(locale, "approvalViaQuotation")}</small></p>}
      </div>
      <div className="card" style={{ marginTop: "1rem" }}>
        <h2>{t(locale, "technicians")}</h2>
        <ul>{(asg ?? []).map((a) => <li key={a.id}>{tname.get(a.technician_id) ?? a.technician_id}{" "}
          {w && <form action={unassignTechnician} style={{ display: "inline" }}><input type="hidden" name="id" value={a.id} /><input type="hidden" name="case_id" value={c.id} />
            <button className="link" type="submit">{t(locale, "endLink")}</button></form>}</li>)}</ul>
        {w && !["closed", "cancelled"].includes(c.status) && (
          <form action={assignTechnician} style={{ display: "flex", gap: ".5rem" }}>
            <input type="hidden" name="case_id" value={c.id} />
            <select name="technician_id" aria-label={t(locale, "technicians")}>{(techs ?? []).filter((x) => !assigned.has(x.id)).map((x) => <option key={x.id} value={x.id}>{x.full_name || x.email}</option>)}</select>
            <button type="submit">{t(locale, "assign")}</button></form>)}
      </div>
      {canQuote === true && (
        <div className="card" style={{ marginTop: "1rem" }}>
          <h2>{t(locale, "quotations")}</h2>
          <ul>{(quotes ?? []).map((x) => <li key={x.id}><a href={`/management/quotations/${x.id}`}>#{x.quotation_no} / {x.revision}</a> — {t(locale, `qs_${x.status}` as never)} ({x.currency})</li>)}</ul>
          {["product_selection", "quotation"].includes(c.status) && (
            <QuotationForm caseId={c.id} l={{ currency: t(locale, "currency"), taxRate: t(locale, "taxRate"), save: t(locale, "newQuotation"),
              err_invalid: t(locale, "invalidInput"), err_forbidden: t(locale, "errForbidden"), err_failed: t(locale, "errFailed") }} />)}
        </div>)}
      <div className="card" style={{ marginTop: "1rem" }}>
        <h2>{t(locale, "measurements")}</h2>
        <ul>{(meas ?? []).map((m) => <li key={m.id}>{m.label}: {m.value} {m.unit}{m.side ? ` (${m.side})` : ""}</li>)}</ul>
        {(meas ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
      </div>
      <div className="card" style={{ marginTop: "1rem" }}>
        <h2>{t(locale, "history")}</h2>
        <ul>{(events ?? []).map((e) => <li key={e.id}><small dir="ltr">{new Date(e.created_at).toISOString().slice(0, 16).replace("T", " ")}</small>{" "}
          {e.event_type}{e.to_status ? `: ${e.from_status ? S(e.from_status) + " → " : ""}${S(e.to_status)}` : ""}{e.event_type === "status_change" && e.note ? ` — ${e.note}` : ""}</li>)}</ul>
      </div>
    </Shell>
  );
}
