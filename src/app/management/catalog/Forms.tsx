"use client";
import { useActionState } from "react";
import { createCategory, createProduct, addPrice, type CatState } from "./actions";
type Opt = { id: string; label: string };
type L = Record<string, string>;
const Msg = ({ s, l }: { s: CatState; l: L }) => (<>
  {s?.error && <p role="alert" className="error">{l[`err_${s.error}`]}</p>}
  {s?.ok && <p role="status">{l.saved}</p>}</>);

export function CategoryForm({ l }: { l: L }) {
  const [s, a, p] = useActionState(createCategory, undefined);
  return (<form action={a} noValidate key={s?.ok ? "ok" : "f"}>
    <label htmlFor="cname">{l.category}</label><input id="cname" name="name" required maxLength={200} />
    <Msg s={s} l={l} /><p><button type="submit" disabled={p}>{l.save}</button></p></form>);
}
export function ProductForm({ manufacturers, categories, l }: { manufacturers: Opt[]; categories: Opt[]; l: L }) {
  const [s, a, p] = useActionState(createProduct, undefined);
  return (<form action={a} noValidate key={s?.ok ? "ok" : "f"}>
    <label htmlFor="manufacturer_id">{l.manufacturer}</label>
    <select id="manufacturer_id" name="manufacturer_id" required>{manufacturers.map((m) => <option key={m.id} value={m.id}>{m.label}</option>)}</select>
    <label htmlFor="category_id">{l.category}</label>
    <select id="category_id" name="category_id"><option value="">—</option>{categories.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}</select>
    <label htmlFor="pname">{l.fullName}</label><input id="pname" name="name" required maxLength={300} />
    <label htmlFor="sku">{l.sku}</label><input id="sku" name="sku" required maxLength={100} dir="ltr" />
    <label htmlFor="pdesc">{l.details}</label><input id="pdesc" name="description" maxLength={2000} />
    <Msg s={s} l={l} /><p><button type="submit" disabled={p}>{l.save}</button></p></form>);
}
export function PriceForm({ products, l }: { products: Opt[]; l: L }) {
  const [s, a, p] = useActionState(addPrice, undefined);
  return (<form action={a} noValidate key={s?.ok ? "ok" : "f"}>
    <label htmlFor="product_id">{l.product}</label>
    <select id="product_id" name="product_id" required>{products.map((x) => <option key={x.id} value={x.id}>{x.label}</option>)}</select>
    <label htmlFor="price">{l.price}</label><input id="price" name="price" type="number" step="0.01" min="0" required dir="ltr" />
    <label htmlFor="currency">{l.currency}</label><input id="currency" name="currency" required maxLength={3} minLength={3} dir="ltr" placeholder="ISO 4217" />
    <Msg s={s} l={l} /><p><button type="submit" disabled={p}>{l.save}</button></p></form>);
}
