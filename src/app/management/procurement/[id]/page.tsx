import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";
import { POItemForm } from "../Forms";
import { removePOItem, setPOStatus } from "../actions";

export default async function POPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: po } = await supabase.from("purchase_orders").select("id,po_no,supplier_id,status,currency").eq("id", id).maybeSingle();
  if (!po) notFound();
  const [{ data: lines }, { data: items }, { data: sup }, { data: canProc }, { data: canInv }] = await Promise.all([
    supabase.from("purchase_order_items").select("id,item_id,quantity,unit_cost").eq("po_id", id).order("seq"),
    supabase.from("inventory_items").select("id,name,sku,is_active").order("name"),
    supabase.from("suppliers").select("name").eq("id", po.supplier_id).maybeSingle(),
    supabase.rpc("has_permission", { p_code: "procurement.manage" }),
    supabase.rpc("has_permission", { p_code: "inventory.manage" }),
  ]);
  const iname = new Map((items ?? []).map((i) => [i.id, i.name]));
  const total = Math.round((lines ?? []).reduce((a, x) => a + Number(x.quantity) * Number(x.unit_cost), 0) * 100) / 100;
  const l = { item: t(locale, "item"), quantity: t(locale, "quantity"), unitCost: t(locale, "unitCost"), add: t(locale, "add"), saved: t(locale, "saved"),
    err_invalid: t(locale, "invalidInput"), err_forbidden: t(locale, "errForbidden"), err_duplicate: t(locale, "errDuplicateItem"), err_failed: t(locale, "errFailed") };
  const draft = po.status === "draft";
  const btn = (to: string, label: string) => (<form action={setPOStatus} style={{ display: "inline" }}><input type="hidden" name="id" value={po.id} /><input type="hidden" name="to" value={to} /><button type="submit">{label}</button></form>);
  return (
    <Shell locale={locale} role="management">
      <div className="card">
        <h1>PO #{po.po_no} — {sup?.name}</h1>
        <p>{t(locale, "status")}: <strong>{t(locale, `po_${po.status}` as never)}</strong> · {po.currency}</p>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead><tr><th scope="col">{t(locale, "item")}</th><th scope="col">{t(locale, "quantity")}</th><th scope="col">{t(locale, "unitCost")}</th><th scope="col"><span className="sr-only">{t(locale, "remove")}</span></th></tr></thead>
          <tbody>{(lines ?? []).map((x) => (<tr key={x.id}><td>{iname.get(x.item_id)}</td><td dir="ltr">{x.quantity}</td><td dir="ltr">{x.unit_cost}</td>
            <td>{draft && canProc === true && <form action={removePOItem}><input type="hidden" name="id" value={x.id} /><input type="hidden" name="po_id" value={po.id} /><button className="link" type="submit">{t(locale, "remove")}</button></form>}</td></tr>))}</tbody>
        </table>
        <p dir="ltr"><strong>{t(locale, "total")}: {total} {po.currency}</strong></p>
        <p>
          {draft && canProc === true && btn("ordered", t(locale, "markOrdered"))}{" "}
          {["draft", "ordered"].includes(po.status) && canProc === true && btn("cancelled", t(locale, "cancel"))}{" "}
          {po.status === "ordered" && canInv === true && btn("received", t(locale, "markReceived"))}</p>
      </div>
      {draft && canProc === true && (items ?? []).some((i) => i.is_active) && <div className="card" style={{ marginTop: "1rem" }}><h2>{t(locale, "addItem")}</h2>
        <POItemForm poId={po.id} l={l} items={(items ?? []).filter((i) => i.is_active).map((i) => ({ id: i.id, label: `${i.name} (${i.sku})` }))} /></div>}
    </Shell>
  );
}
