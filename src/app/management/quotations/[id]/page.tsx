import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";
import { ItemForm } from "../ItemForm";
import { issueInvoice, setVisibility } from "../../finance/actions";
import { removeItem, setDiscount, submitQuotation, approveQuotation, rejectQuotation, reviseQuotation } from "../actions";

export default async function QuotationPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: q } = await supabase.from("quotations")
    .select("id,quotation_no,case_id,revision,status,currency,tax_rate,discount_percent,rejection_reason,snapshot").eq("id", id).maybeSingle();
  if (!q) notFound(); // also the answer for roles without quotation access
  const [{ data: items }, { data: totals }, { data: prods }, { data: mf }, { data: canDiscount }, { data: canApprove }, { data: canFin }, { data: inv }, { data: vis }] = await Promise.all([
    supabase.from("quotation_items").select("id,item_type,description,quantity,unit_price,line_total").eq("quotation_id", id).order("seq"),
    supabase.rpc("quotation_totals", { p_q: id }),
    supabase.from("products").select("id,name,sku,manufacturer_id").eq("is_active", true).order("name"),
    supabase.from("manufacturers").select("id,name"),
    supabase.rpc("has_permission", { p_code: "quotations.discount" }),
    supabase.rpc("has_permission", { p_code: "quotations.approve" }),
    supabase.rpc("has_permission", { p_code: "finance.manage" }),
    supabase.from("invoices").select("id,invoice_no").eq("quotation_id", id).maybeSingle(),
    supabase.rpc("visibility_of", { p_kind: "quotation" }),
  ]);
  const tot = (totals ?? [])[0];
  const mname = new Map((mf ?? []).map((m) => [m.id, m.name]));
  const draft = q.status === "draft";
  const l = {
    itemType: t(locale, "itemType"), product: t(locale, "product"), material: t(locale, "material"), service: t(locale, "service"),
    details: t(locale, "details"), price: t(locale, "price"), quantity: t(locale, "quantity"), add: t(locale, "add"),
    autoPrice: t(locale, "autoPrice"), err_invalid: t(locale, "invalidInput"), err_forbidden: t(locale, "errForbidden"),
    err_failed: t(locale, "errFailed"), err_noPrice: t(locale, "errNoPrice"),
  };
  const snap = q.snapshot as { total?: number } | null;
  return (
    <Shell locale={locale} role="management">
      <div className="card">
        <h1>{t(locale, "quotation")} #{q.quotation_no} / {q.revision}</h1>
        <p>{t(locale, "status")}: <strong>{t(locale, `qs_${q.status}` as never)}</strong> · {q.currency} · {t(locale, "taxRate")} {q.tax_rate}% · {t(locale, "discount")} {q.discount_percent}%</p>
        <p><a href={`/management/cases/${q.case_id}`}>{t(locale, "cases")}</a></p>
        {q.rejection_reason && <p role="status">{t(locale, "rejectionReason")}: {q.rejection_reason}</p>}
        {q.status === "approved" && <p><a href={`/management/quotations/${q.id}/print`}>{t(locale, "printSave")}</a></p>}
        {q.status === "approved" && (() => { const on = (vis ?? []).some((v: { ref_id: string; visible: boolean }) => v.ref_id === q.id && v.visible); return (
          <form action={setVisibility}><input type="hidden" name="kind" value="quotation" /><input type="hidden" name="id" value={q.id} />
            <input type="hidden" name="visible" value={on ? "false" : "true"} />
            <p>{on ? t(locale, "sharedWithPatient") : t(locale, "notSharedWithPatient")} <button type="submit">{on ? t(locale, "hideFromPatient") : t(locale, "shareWithPatient")}</button></p></form>); })()}
        {q.status === "approved" && <p role="status">{t(locale, "snapshotFrozen")}{snap?.total != null ? ` — ${snap.total} ${q.currency}` : ""}</p>}
      </div>
      <div className="card" style={{ marginTop: "1rem" }}>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead><tr><th scope="col">{t(locale, "details")}</th><th scope="col">{t(locale, "quantity")}</th><th scope="col">{t(locale, "price")}</th><th scope="col">{t(locale, "total")}</th><th scope="col"><span className="sr-only">{t(locale, "add")}</span></th></tr></thead>
          <tbody>{(items ?? []).map((i) => (
            <tr key={i.id}><td>{i.description}</td><td dir="ltr">{i.quantity}</td><td dir="ltr">{i.unit_price}</td><td dir="ltr">{i.line_total}</td>
              <td>{draft && <form action={removeItem}><input type="hidden" name="id" value={i.id} /><input type="hidden" name="quotation_id" value={q.id} /><button className="link" type="submit">{t(locale, "remove")}</button></form>}</td></tr>))}</tbody>
        </table>
        {(items ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
        {tot && <dl>
          <dt>{t(locale, "subtotal")}</dt><dd dir="ltr">{tot.subtotal} {q.currency}</dd>
          <dt>{t(locale, "discount")}</dt><dd dir="ltr">− {tot.discount_amount}</dd>
          <dt>{t(locale, "tax")}</dt><dd dir="ltr">{tot.tax_amount}</dd>
          <dt>{t(locale, "total")}</dt><dd dir="ltr"><strong>{tot.total} {q.currency}</strong></dd></dl>}
      </div>
      {draft && (<>
        <div className="card" style={{ marginTop: "1rem" }}><h2>{t(locale, "addItem")}</h2>
          <ItemForm quotationId={q.id} l={l} products={(prods ?? []).map((p) => ({ id: p.id, label: `${mname.get(p.manufacturer_id)} — ${p.name} (${p.sku})` }))} /></div>
        {canDiscount === true && <div className="card" style={{ marginTop: "1rem" }}>
          <form action={setDiscount} style={{ display: "flex", gap: ".5rem", alignItems: "end" }}><input type="hidden" name="id" value={q.id} />
            <div><label htmlFor="dp">{t(locale, "discount")} %</label><input id="dp" name="discount_percent" type="number" step="0.01" min="0" max="100" defaultValue={q.discount_percent} dir="ltr" /></div>
            <button type="submit">{t(locale, "save")}</button></form></div>}
        <form action={submitQuotation} style={{ marginTop: "1rem" }}><input type="hidden" name="id" value={q.id} /><button type="submit">{t(locale, "submitForApproval")}</button></form>
      </>)}
      {q.status === "submitted" && (<div className="card" style={{ marginTop: "1rem" }}>
        {canApprove === true ? (<div style={{ display: "flex", gap: "1rem", flexWrap: "wrap" }}>
          <form action={approveQuotation}><input type="hidden" name="id" value={q.id} /><button type="submit">{t(locale, "approve")}</button></form>
          <form action={rejectQuotation} style={{ display: "flex", gap: ".5rem" }}><input type="hidden" name="id" value={q.id} />
            <input name="reason" required maxLength={1000} aria-label={t(locale, "rejectionReason")} placeholder={t(locale, "rejectionReason")} />
            <button type="submit">{t(locale, "reject")}</button></form></div>) : <p>{t(locale, "awaitingApproval")}</p>}
        <form action={reviseQuotation} style={{ marginTop: "1rem" }}><input type="hidden" name="id" value={q.id} /><button className="link" type="submit">{t(locale, "revise")}</button></form>
      </div>)}
      {q.status === "approved" && canFin === true && (inv
        ? <p style={{ marginTop: "1rem" }}><a href="/management/finance">{t(locale, "invoice")} #{inv.invoice_no}</a></p>
        : <form action={issueInvoice} style={{ marginTop: "1rem" }}><input type="hidden" name="id" value={q.id} /><button type="submit">{t(locale, "issueInvoice")}</button></form>)}
      {q.status === "rejected" && <form action={reviseQuotation} style={{ marginTop: "1rem" }}><input type="hidden" name="id" value={q.id} /><button type="submit">{t(locale, "revise")}</button></form>}
    </Shell>
  );
}
