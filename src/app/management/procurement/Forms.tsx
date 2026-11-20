"use client";
import { useActionState } from "react";
import { createSupplier, createPO, addPOItem, type ProcState } from "./actions";
type L = Record<string, string>; type Opt = { id: string; label: string };
const Msg = ({ s, l }: { s: ProcState; l: L }) => (<>
  {s?.error && <p role="alert" className="error">{l[`err_${s.error}`]}</p>}{s?.ok && <p role="status">{l.saved}</p>}</>);
export function SupplierForm({ l }: { l: L }) {
  const [s, a, p] = useActionState(createSupplier, undefined);
  return (<form action={a} noValidate key={s?.ok ? "ok" : "f"}>
    <label htmlFor="sname">{l.fullName}</label><input id="sname" name="name" required maxLength={200} />
    <label htmlFor="scontact">{l.contact}</label><input id="scontact" name="contact" maxLength={500} />
    <Msg s={s} l={l} /><p><button type="submit" disabled={p}>{l.save}</button></p></form>);
}
export function POForm({ suppliers, l }: { suppliers: Opt[]; l: L }) {
  const [s, a, p] = useActionState(createPO, undefined);
  return (<form action={a} noValidate>
    <label htmlFor="supplier_id">{l.supplier}</label>
    <select id="supplier_id" name="supplier_id" required>{suppliers.map((x) => <option key={x.id} value={x.id}>{x.label}</option>)}</select>
    <label htmlFor="pcur">{l.currency}</label><input id="pcur" name="currency" required minLength={3} maxLength={3} dir="ltr" placeholder="ISO 4217" />
    <Msg s={s} l={l} /><p><button type="submit" disabled={p}>{l.save}</button></p></form>);
}
export function POItemForm({ poId, items, l }: { poId: string; items: Opt[]; l: L }) {
  const [s, a, p] = useActionState(addPOItem, undefined);
  return (<form action={a} noValidate key={s?.ok ? "ok" : "f"}>
    <input type="hidden" name="po_id" value={poId} />
    <label htmlFor="item_id">{l.item}</label>
    <select id="item_id" name="item_id" required>{items.map((x) => <option key={x.id} value={x.id}>{x.label}</option>)}</select>
    <label htmlFor="pq">{l.quantity}</label><input id="pq" name="quantity" type="number" step="0.01" min="0.01" required dir="ltr" />
    <label htmlFor="pc">{l.unitCost}</label><input id="pc" name="unit_cost" type="number" step="0.01" min="0" required dir="ltr" />
    <Msg s={s} l={l} /><p><button type="submit" disabled={p}>{l.add}</button></p></form>);
}
