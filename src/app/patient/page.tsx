import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";

// Everything here is filtered by RLS to the signed-in patient's own approved data.
const FLOW = ["assessment", "product_selection", "quotation", "approved", "production", "quality_control", "fitting", "delivered", "follow_up", "closed"] as const;

export default async function PatientHome() {
  const locale = await getLocale();
  const supabase = await createClient();
  const [{ data: cases }, { data: appts }, { data: reps }, { data: quotes }, { data: invs }] = await Promise.all([
    supabase.from("cases").select("id,case_no,case_type,status").order("case_no", { ascending: false }),
    supabase.from("appointments").select("id,appointment_type,scheduled_at,status").order("scheduled_at", { ascending: false }).limit(20),
    supabase.from("shareable_reports").select("id,title,body,published_at").eq("status", "published").order("published_at", { ascending: false }),
    supabase.rpc("my_quotations"),
    supabase.rpc("my_invoices"),
  ]);
  return (
    <Shell locale={locale} role="patient">
      <div className="card">
        <h1>{t(locale, "myCases")}</h1>
        {(cases ?? []).map((c) => {
          const idx = FLOW.indexOf(c.status as (typeof FLOW)[number]);
          return (
            <section key={c.id} style={{ marginBottom: "1rem" }}>
              <h2>#{c.case_no} — {c.case_type}</h2>
              <p>{t(locale, "status")}: <strong>{t(locale, `st_${c.status}` as never)}</strong></p>
              {idx >= 0 && <progress max={FLOW.length - 1} value={idx} aria-label={t(locale, "status")} />}
            </section>);
        })}
        {(cases ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
      </div>
      <div className="card" style={{ marginTop: "1rem" }}>
        <h2>{t(locale, "appointments")}</h2>
        <ul>{(appts ?? []).map((a) => <li key={a.id}><span dir="ltr">{new Date(a.scheduled_at).toISOString().slice(0, 16).replace("T", " ")}</span> — {t(locale, `ap_${a.appointment_type}` as never)} ({t(locale, `apst_${a.status}` as never)})</li>)}</ul>
        {(appts ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
      </div>
      <div className="card" style={{ marginTop: "1rem" }}>
        <h2>{t(locale, "myQuotations")}</h2>
        {(quotes ?? []).map((q: { quotation_id: string; quotation_no: number; currency: string; snapshot: { items: { description: string; quantity: number; line_total: number; product: { name: string; manufacturer: string } | null }[]; subtotal: number; discount_amount: number; tax_amount: number; total: number } }) => (
          <section key={q.quotation_id} style={{ marginBottom: "1rem" }}>
            <h3>#{q.quotation_no}</h3>
            <ul>{q.snapshot.items.map((i, k) => <li key={k}>{i.product ? `${i.product.manufacturer} — ${i.product.name}` : i.description} × <span dir="ltr">{i.quantity}</span> = <span dir="ltr">{i.line_total} {q.currency}</span></li>)}</ul>
            <p dir="ltr">{t(locale, "subtotal")}: {q.snapshot.subtotal} · {t(locale, "discount")}: −{q.snapshot.discount_amount} · {t(locale, "tax")}: {q.snapshot.tax_amount}</p>
            <p dir="ltr"><strong>{t(locale, "total")}: {q.snapshot.total} {q.currency}</strong></p>
          </section>))}
        {(quotes ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
      </div>
      <div className="card" style={{ marginTop: "1rem" }}>
        <h2>{t(locale, "myInvoices")}</h2>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead><tr><th scope="col">#</th><th scope="col">{t(locale, "amount")}</th><th scope="col">{t(locale, "paid")}</th><th scope="col">{t(locale, "balance")}</th></tr></thead>
          <tbody>{(invs ?? []).map((i: { invoice_id: string; invoice_no: number; currency: string; amount: number; paid: number; balance: number }) => (
            <tr key={i.invoice_id}><td dir="ltr">{i.invoice_no}</td><td dir="ltr">{i.amount} {i.currency}</td><td dir="ltr">{i.paid}</td><td dir="ltr">{i.balance}</td></tr>))}</tbody>
        </table>
        {(invs ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
      </div>
      <div className="card" style={{ marginTop: "1rem" }}>
        <h2>{t(locale, "myReports")}</h2>
        {(reps ?? []).map((r) => (
          <article key={r.id} style={{ marginBottom: "1.5rem" }}>
            <h3>{r.title}</h3><p style={{ whiteSpace: "pre-wrap" }}>{r.body}</p>
            <small>{r.published_at ? new Date(r.published_at).toISOString().slice(0, 10) : ""}</small>
          </article>))}
        {(reps ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
      </div>
    </Shell>
  );
}
