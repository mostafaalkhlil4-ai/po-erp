import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";
import { ItemForm, MovementForm } from "./Forms";

export default async function InventoryPage() {
  const locale = await getLocale();
  const supabase = await createClient();
  const [{ data: items }, { data: levels }, { data: cases }, { data: pts }, { data: canInv }, { data: moves }] = await Promise.all([
    supabase.from("inventory_items").select("id,name,sku,unit,min_stock,is_active").order("name"),
    supabase.rpc("stock_levels"),
    supabase.from("cases").select("id,case_no,patient_id").not("status", "in", "(closed,cancelled)").order("case_no", { ascending: false }),
    supabase.from("patients").select("id,full_name"),
    supabase.rpc("has_permission", { p_code: "inventory.manage" }),
    supabase.from("stock_movements").select("id,item_id,kind,quantity,notes,created_at").order("id", { ascending: false }).limit(30),
  ]);
  if (canInv !== true) return <Shell locale={locale} role="management"><div className="card"><p>{t(locale, "errForbidden")}</p></div></Shell>;
  const lv = new Map<string, number>((levels ?? []).map((x: { item_id: string; on_hand: number }) => [x.item_id, Number(x.on_hand)]));
  const iname = new Map((items ?? []).map((i) => [i.id, i.name]));
  const pn = new Map((pts ?? []).map((p) => [p.id, p.full_name]));
  const l = {
    fullName: t(locale, "fullName"), sku: t(locale, "sku"), unit: t(locale, "unit"), minStock: t(locale, "minStock"), item: t(locale, "item"),
    kind: t(locale, "kind"), quantity: t(locale, "quantity"), caseFor: t(locale, "cases"), notes: t(locale, "notes"),
    mv_receipt: t(locale, "mv_receipt"), mv_issue: t(locale, "mv_issue"), mv_adjust_in: t(locale, "mv_adjust_in"), mv_adjust_out: t(locale, "mv_adjust_out"),
    save: t(locale, "save"), saved: t(locale, "saved"), err_invalid: t(locale, "invalidInput"), err_forbidden: t(locale, "errForbidden"),
    err_duplicate: t(locale, "errDuplicateProduct"), err_stock: t(locale, "errStockRule"), err_failed: t(locale, "errFailed"),
  };
  return (
    <Shell locale={locale} role="management">
      <div className="card">
        <h1>{t(locale, "inventory")}</h1>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead><tr><th scope="col">{t(locale, "fullName")}</th><th scope="col">{t(locale, "sku")}</th><th scope="col">{t(locale, "onHand")}</th><th scope="col">{t(locale, "minStock")}</th></tr></thead>
          <tbody>{(items ?? []).map((i) => { const h = lv.get(i.id) ?? 0; const low = h < Number(i.min_stock); return (
            <tr key={i.id}><td>{i.name}{!i.is_active ? " ⛔" : ""}</td><td dir="ltr">{i.sku}</td>
              <td dir="ltr">{h} {i.unit}{low && <strong role="status"> — {t(locale, "lowStock")}</strong>}</td><td dir="ltr">{i.min_stock}</td></tr>); })}</tbody>
        </table>
        {(items ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
      </div>
      <div className="card" style={{ marginTop: "1rem" }}><h2>{t(locale, "newItem")}</h2><ItemForm l={l} /></div>
      {(items ?? []).some((i) => i.is_active) && <div className="card" style={{ marginTop: "1rem" }}><h2>{t(locale, "newMovement")}</h2>
        <MovementForm l={l} kinds={["receipt", "issue", "adjust_in", "adjust_out"]}
          items={(items ?? []).filter((i) => i.is_active).map((i) => ({ id: i.id, label: `${i.name} (${i.sku})` }))}
          cases={(cases ?? []).map((c) => ({ id: c.id, label: `#${c.case_no} — ${pn.get(c.patient_id) ?? ""}` }))} /></div>}
      <div className="card" style={{ marginTop: "1rem" }}><h2>{t(locale, "movements")}</h2>
        <ul>{(moves ?? []).map((m) => <li key={m.id}><span dir="ltr">{new Date(m.created_at).toISOString().slice(0, 16).replace("T", " ")}</span> — {iname.get(m.item_id)}: {t(locale, `mv_${m.kind}` as never)} <span dir="ltr">{m.quantity}</span>{m.notes ? ` (${m.notes})` : ""}</li>)}</ul></div>
    </Shell>
  );
}
