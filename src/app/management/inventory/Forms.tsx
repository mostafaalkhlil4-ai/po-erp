"use client";
import { useActionState } from "react";
import { createItem, addMovement, type InvState } from "./actions";
type L = Record<string, string>; type Opt = { id: string; label: string };
const Msg = ({ s, l }: { s: InvState; l: L }) => (<>
  {s?.error && <p role="alert" className="error">{l[`err_${s.error}`]}</p>}{s?.ok && <p role="status">{l.saved}</p>}</>);
export function ItemForm({ l }: { l: L }) {
  const [s, a, p] = useActionState(createItem, undefined);
  return (<form action={a} noValidate key={s?.ok ? "ok" : "f"}>
    <label htmlFor="iname">{l.fullName}</label><input id="iname" name="name" required maxLength={200} />
    <label htmlFor="isku">{l.sku}</label><input id="isku" name="sku" required maxLength={100} dir="ltr" />
    <label htmlFor="iunit">{l.unit}</label><input id="iunit" name="unit" required maxLength={30} />
    <label htmlFor="imin">{l.minStock}</label><input id="imin" name="min_stock" type="number" step="0.01" min="0" defaultValue="0" dir="ltr" />
    <Msg s={s} l={l} /><p><button type="submit" disabled={p}>{l.save}</button></p></form>);
}
// kinds: staff may pick any; technicians get only "issue" (case fixed)
export function MovementForm({ items, kinds, caseId, cases, l }: { items: Opt[]; kinds: string[]; caseId?: string; cases?: Opt[]; l: L }) {
  const [s, a, p] = useActionState(addMovement, undefined);
  return (<form action={a} noValidate key={s?.ok ? "ok" : "f"}>
    <label htmlFor="item_id">{l.item}</label>
    <select id="item_id" name="item_id" required>{items.map((x) => <option key={x.id} value={x.id}>{x.label}</option>)}</select>
    <label htmlFor="kind">{l.kind}</label>
    <select id="kind" name="kind">{kinds.map((k) => <option key={k} value={k}>{l[`mv_${k}`]}</option>)}</select>
    <label htmlFor="mqty">{l.quantity}</label><input id="mqty" name="quantity" type="number" step="0.01" min="0.01" required dir="ltr" />
    {caseId ? <input type="hidden" name="case_id" value={caseId} /> : (<>
      <label htmlFor="mcase">{l.caseFor}</label>
      <select id="mcase" name="case_id"><option value="">—</option>{(cases ?? []).map((x) => <option key={x.id} value={x.id}>{x.label}</option>)}</select></>)}
    <label htmlFor="mnotes">{l.notes}</label><input id="mnotes" name="notes" maxLength={1000} />
    <Msg s={s} l={l} /><p><button type="submit" disabled={p}>{l.save}</button></p></form>);
}
