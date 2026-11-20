import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { PrintButton } from "@/components/PrintButton";

type Snap = { items: { description: string; quantity: number; unit_price: number; line_total: number; product: { name: string; sku: string; manufacturer: string } | null }[];
  subtotal: number; discount_percent: number; discount_amount: number; tax_rate: number; tax_amount: number; total: number; captured_at: string };

// Printable (browser "Save as PDF") view of the immutable approved snapshot - never of live prices.
export default async function QuotationPrint({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: q } = await supabase.from("quotations").select("quotation_no,revision,currency,status,snapshot,approved_at,case_id").eq("id", id).maybeSingle();
  if (!q || q.status !== "approved" || !q.snapshot) notFound();
  const s = q.snapshot as Snap;
  const { data: c } = await supabase.from("cases").select("case_no,patient_id").eq("id", q.case_id).maybeSingle();
  const { data: p } = c ? await supabase.from("patients").select("full_name,file_no").eq("id", c.patient_id).maybeSingle() : { data: null };
  return (
    <main style={{ maxWidth: 800 }}>
      <style>{`@media print{.no-print{display:none}body{background:#fff}main{padding:0}}`}</style>
      <h1>{t(locale, "quotation")} #{q.quotation_no} / {q.revision}</h1>
      <p>{p?.full_name} {p ? `#${p.file_no}` : ""} · {t(locale, "cases")} #{c?.case_no} · <span dir="ltr">{q.approved_at?.slice(0, 10)}</span></p>
      <table style={{ width: "100%", borderCollapse: "collapse" }}>
        <thead><tr><th scope="col">{t(locale, "details")}</th><th scope="col">{t(locale, "quantity")}</th><th scope="col">{t(locale, "price")}</th><th scope="col">{t(locale, "total")}</th></tr></thead>
        <tbody>{s.items.map((i, k) => (<tr key={k}>
          <td>{i.product ? `${i.product.manufacturer} — ${i.product.name} (${i.product.sku})` : i.description}</td>
          <td dir="ltr">{i.quantity}</td><td dir="ltr">{i.unit_price}</td><td dir="ltr">{i.line_total}</td></tr>))}</tbody>
      </table>
      <dl dir="ltr">
        <dt>{t(locale, "subtotal")}</dt><dd>{s.subtotal} {q.currency}</dd>
        <dt>{t(locale, "discount")} ({s.discount_percent}%)</dt><dd>− {s.discount_amount}</dd>
        <dt>{t(locale, "tax")} ({s.tax_rate}%)</dt><dd>{s.tax_amount}</dd>
        <dt>{t(locale, "total")}</dt><dd><strong>{s.total} {q.currency}</strong></dd>
      </dl>
      <PrintButton label={t(locale, "printSave")} />
    </main>
  );
}
