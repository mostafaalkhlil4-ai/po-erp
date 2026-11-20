"use client";
import { useActionState } from "react";
import { recordPayment, addExpense, type FinState } from "./actions";
type L = Record<string, string>;
const Msg = ({ s, l }: { s: FinState; l: L }) => (<>
  {s?.error && <p role="alert" className="error">{l[`err_${s.error}`]}</p>}
  {s?.ok && <p role="status">{l.saved}</p>}</>);

export function PaymentForm({ invoices, l }: { invoices: { id: string; label: string }[]; l: L }) {
  const [s, a, p] = useActionState(recordPayment, undefined);
  return (<form action={a} noValidate key={s?.ok ? "ok" : "f"}>
    <label htmlFor="invoice_id">{l.invoice}</label>
    <select id="invoice_id" name="invoice_id" required>{invoices.map((i) => <option key={i.id} value={i.id}>{i.label}</option>)}</select>
    <label htmlFor="amount">{l.amount}</label><input id="amount" name="amount" type="number" step="0.01" min="0.01" required dir="ltr" />
    <label htmlFor="method">{l.method}</label>
    <select id="method" name="method"><option value="cash">{l.cash}</option><option value="bank_transfer">{l.bank_transfer}</option><option value="card">{l.card}</option><option value="other">{l.other}</option></select>
    <label htmlFor="reference">{l.reference}</label><input id="reference" name="reference" maxLength={200} dir="ltr" />
    <Msg s={s} l={l} /><p><button type="submit" disabled={p}>{l.save}</button></p></form>);
}
export function ExpenseForm({ l }: { l: L }) {
  const [s, a, p] = useActionState(addExpense, undefined);
  return (<form action={a} noValidate key={s?.ok ? "ok" : "f"}>
    <label htmlFor="category">{l.category}</label><input id="category" name="category" required maxLength={100} />
    <label htmlFor="description">{l.details}</label><input id="description" name="description" maxLength={1000} />
    <label htmlFor="eamount">{l.amount}</label><input id="eamount" name="amount" type="number" step="0.01" min="0.01" required dir="ltr" />
    <label htmlFor="ecurrency">{l.currency}</label><input id="ecurrency" name="currency" required minLength={3} maxLength={3} dir="ltr" placeholder="ISO 4217" />
    <label htmlFor="incurred_on">{l.date}</label><input id="incurred_on" name="incurred_on" type="date" required dir="ltr" />
    <Msg s={s} l={l} /><p><button type="submit" disabled={p}>{l.save}</button></p></form>);
}
