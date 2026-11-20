import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";
import { SupplierForm, POForm } from "./Forms";

export default async function ProcurementPage() {
  const locale = await getLocale();
  const supabase = await createClient();
  const [{ data: sups }, { data: pos }, { data: canProc }] = await Promise.all([
    supabase.from("suppliers").select("id,name,is_active").order("name"),
    supabase.from("purchase_orders").select("id,po_no,supplier_id,status,currency").order("po_no", { ascending: false }).limit(100),
    supabase.rpc("has_permission", { p_code: "procurement.manage" }),
  ]);
  if (canProc !== true) return <Shell locale={locale} role="management"><div className="card"><p>{t(locale, "errForbidden")}</p></div></Shell>;
  const sn = new Map((sups ?? []).map((s) => [s.id, s.name]));
  const l = { fullName: t(locale, "fullName"), contact: t(locale, "contact"), supplier: t(locale, "supplier"), currency: t(locale, "currency"),
    save: t(locale, "save"), saved: t(locale, "saved"), err_invalid: t(locale, "invalidInput"), err_forbidden: t(locale, "errForbidden"),
    err_duplicate: t(locale, "errDuplicateProduct"), err_failed: t(locale, "errFailed") };
  return (
    <Shell locale={locale} role="management">
      <div className="card">
        <h1>{t(locale, "procurement")}</h1>
        <ul>{(pos ?? []).map((p) => <li key={p.id}><a href={`/management/procurement/${p.id}`}>PO #{p.po_no}</a> — {sn.get(p.supplier_id)} ({p.currency}) — {t(locale, `po_${p.status}` as never)}</li>)}</ul>
        {(pos ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
      </div>
      {(sups ?? []).some((s) => s.is_active) && <div className="card" style={{ marginTop: "1rem" }}><h2>{t(locale, "newPO")}</h2>
        <POForm l={l} suppliers={(sups ?? []).filter((s) => s.is_active).map((s) => ({ id: s.id, label: s.name }))} /></div>}
      <div className="card" style={{ marginTop: "1rem" }}><h2>{t(locale, "suppliers")}</h2>
        <ul>{(sups ?? []).map((s) => <li key={s.id}>{s.name}{!s.is_active ? " ⛔" : ""}</li>)}</ul><SupplierForm l={l} /></div>
    </Shell>
  );
}
