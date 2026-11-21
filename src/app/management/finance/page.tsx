import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";
import { PaymentForm, ExpenseForm } from "./Forms";
import { voidInvoice, setVisibility } from "./actions";

export default async function FinancePage() {
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: canFin } = await supabase.rpc("has_permission", { p_code: "finance.manage" });
  const [{ data: invs }, { data: pays }, { data: exps }, { data: vis }] = await Promise.all([
    supabase.from("invoices").select("id,invoice_no,patient_id,currency,amount,status,void_reason").order("invoice_no", { ascending: false }),
    supabase.from("payments").select("invoice_id,amount"),
    supabase.from("expenses").select("id,category,description,amount,currency,incurred_on").order("incurred_on", { ascending: false }).limit(50),
    supabase.rpc("visibility_of", { p_kind: "invoice" }),
  ]);
  const { data: pts } = await supabase.from("patients").select("id,full_name").in("id", [...new Set((invs ?? []).map((i) => i.patient_id))]);
  const pname = new Map((pts ?? []).map((p) => [p.id, p.full_name]));
  const shared = new Map<string, boolean>((vis ?? []).map((v: { ref_id: string; visible: boolean }) => [v.ref_id, v.visible]));
  const paid = new Map<string, number>();
  for (const p of pays ?? []) paid.set(p.invoice_id, Math.round(((paid.get(p.invoice_id) ?? 0) + Number(p.amount)) * 100) / 100);
  const open = (invs ?? []).filter((i) => i.status === "issued" && Number(i.amount) - (paid.get(i.id) ?? 0) > 0);
  const l = {
    invoice: t(locale, "invoice"), amount: t(locale, "amount"), method: t(locale, "method"), reference: t(locale, "reference"),
    cash: t(locale, "mCash"), bank_transfer: t(locale, "mBank"), card: t(locale, "mCard"), other: t(locale, "mOther"),
    category: t(locale, "category"), details: t(locale, "details"), currency: t(locale, "currency"), date: t(locale, "date"),
    save: t(locale, "save"), saved: t(locale, "saved"), err_invalid: t(locale, "invalidInput"), err_forbidden: t(locale, "errForbidden"),
    err_exceeds: t(locale, "errPaymentRule"), err_failed: t(locale, "errFailed"),
  };
  if (canFin !== true) return <Shell locale={locale} role="management"><div className="card"><p>{t(locale, "errForbidden")}</p></div></Shell>;
  return (
    <Shell locale={locale} role="management">
      <div className="card">
        <h1>{t(locale, "finance")}</h1>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead><tr><th scope="col">#</th><th scope="col">{t(locale, "patients")}</th><th scope="col">{t(locale, "amount")}</th><th scope="col">{t(locale, "paid")}</th><th scope="col">{t(locale, "balance")}</th><th scope="col">{t(locale, "status")}</th></tr></thead>
          <tbody>{(invs ?? []).map((i) => { const p = paid.get(i.id) ?? 0; return (
            <tr key={i.id}><td dir="ltr">{i.invoice_no}</td><td>{pname.get(i.patient_id) ?? "—"}</td>
              <td dir="ltr">{i.amount} {i.currency}</td><td dir="ltr">{p}</td><td dir="ltr">{(Math.round((Number(i.amount) - p) * 100) / 100)}</td>
              <td>{i.status === "void" ? `${t(locale, "void")}: ${i.void_reason}` : t(locale, "issued")}
                {i.status === "issued" && (
                  <form action={setVisibility} style={{ display: "inline", marginInlineStart: ".5rem" }}>
                    <input type="hidden" name="kind" value="invoice" /><input type="hidden" name="id" value={i.id} />
                    <input type="hidden" name="visible" value={shared.get(i.id) ? "false" : "true"} />
                    <button className="link" type="submit">{shared.get(i.id) ? t(locale, "hideFromPatient") : t(locale, "shareWithPatient")}</button></form>)}
                {i.status === "issued" && p === 0 && (
                  <form action={voidInvoice} style={{ display: "inline-flex", gap: ".25rem", marginInlineStart: ".5rem" }}>
                    <input type="hidden" name="id" value={i.id} />
                    <input name="reason" required maxLength={1000} aria-label={t(locale, "rejectionReason")} placeholder={t(locale, "rejectionReason")} />
                    <button className="link" type="submit">{t(locale, "void")}</button></form>)}</td></tr>); })}</tbody>
        </table>
        {(invs ?? []).length === 0 && <p>{t(locale, "invoicesEmpty")}</p>}
      </div>
      {open.length > 0 && <div className="card" style={{ marginTop: "1rem" }}><h2>{t(locale, "recordPayment")}</h2>
        <PaymentForm l={l} invoices={open.map((i) => ({ id: i.id, label: `#${i.invoice_no} — ${pname.get(i.patient_id) ?? ""} (${i.currency})` }))} /></div>}
      <div className="card" style={{ marginTop: "1rem" }}><h2>{t(locale, "expenses")}</h2>
        <ul>{(exps ?? []).map((e) => <li key={e.id}><span dir="ltr">{e.incurred_on}</span> — {e.category}: <span dir="ltr">{e.amount} {e.currency}</span></li>)}</ul>
        <ExpenseForm l={l} /></div>
    </Shell>
  );
}
