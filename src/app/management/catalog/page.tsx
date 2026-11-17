import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";
import { CategoryForm, ProductForm, PriceForm } from "./Forms";

export default async function CatalogPage() {
  const locale = await getLocale();
  const supabase = await createClient();
  const [{ data: mf }, { data: cats }, { data: prods }, { data: canManage }] = await Promise.all([
    supabase.from("manufacturers").select("id,name").order("name"),
    supabase.from("product_categories").select("id,name").order("name"),
    supabase.from("products").select("id,name,sku,manufacturer_id,category_id,is_active").order("name"),
    supabase.rpc("has_permission", { p_code: "catalog.manage" }),
  ]);
  // Prices are returned by RLS only to catalog/quotation staff.
  const { data: prices } = await supabase.from("product_price_history").select("product_id,price,currency,valid_from,id").order("id", { ascending: false });
  const latest = new Map<string, { price: number; currency: string }>();
  for (const p of prices ?? []) if (!latest.has(p.product_id)) latest.set(p.product_id, { price: p.price, currency: p.currency });
  const mname = new Map((mf ?? []).map((m) => [m.id, m.name]));
  const cname = new Map((cats ?? []).map((c) => [c.id, c.name]));
  const showPrices = (prices ?? []).length > 0 || canManage === true;
  const l = {
    category: t(locale, "category"), manufacturer: t(locale, "manufacturer"), fullName: t(locale, "fullName"), sku: t(locale, "sku"),
    details: t(locale, "details"), product: t(locale, "product"), price: t(locale, "price"), currency: t(locale, "currency"),
    save: t(locale, "save"), saved: t(locale, "saved"),
    err_invalid: t(locale, "invalidInput"), err_forbidden: t(locale, "errForbidden"), err_failed: t(locale, "errFailed"),
    err_duplicate: t(locale, "errDuplicateProduct"),
  };
  const opts = (prods ?? []).filter((p) => p.is_active).map((p) => ({ id: p.id, label: `${mname.get(p.manufacturer_id)} — ${p.name} (${p.sku})` }));
  return (
    <Shell locale={locale} role={canManage === true ? "management" : undefined}>
      <div className="card">
        <h1>{t(locale, "catalog")}</h1>
        <p><small>{t(locale, "approvedManufacturers")}: {(mf ?? []).map((m) => m.name).join("، ")}</small></p>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead><tr><th scope="col">{t(locale, "manufacturer")}</th><th scope="col">{t(locale, "fullName")}</th><th scope="col">{t(locale, "sku")}</th><th scope="col">{t(locale, "category")}</th>{showPrices && <th scope="col">{t(locale, "price")}</th>}</tr></thead>
          <tbody>{(prods ?? []).map((p) => { const pr = latest.get(p.id); return (
            <tr key={p.id}><td>{mname.get(p.manufacturer_id)}</td><td>{p.name}</td><td dir="ltr">{p.sku}</td><td>{p.category_id ? cname.get(p.category_id) : "—"}</td>
              {showPrices && <td dir="ltr">{pr ? `${pr.price} ${pr.currency}` : "—"}</td>}</tr>); })}</tbody>
        </table>
        {(prods ?? []).length === 0 && <p>{t(locale, "catalogEmpty")}</p>}
      </div>
      {canManage === true && (<>
        <div className="card" style={{ marginTop: "1rem" }}><h2>{t(locale, "category")}</h2><CategoryForm l={l} /></div>
        <div className="card" style={{ marginTop: "1rem" }}><h2>{t(locale, "newProduct")}</h2>
          <ProductForm l={l} manufacturers={(mf ?? []).map((m) => ({ id: m.id, label: m.name }))} categories={(cats ?? []).map((c) => ({ id: c.id, label: c.name }))} /></div>
        {opts.length > 0 && <div className="card" style={{ marginTop: "1rem" }}><h2>{t(locale, "newPrice")}</h2><PriceForm l={l} products={opts} /></div>}
      </>)}
    </Shell>
  );
}
