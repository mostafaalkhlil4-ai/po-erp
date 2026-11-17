"use client";
import { useActionState } from "react";
import { createQuotation } from "./actions";
export function QuotationForm({ caseId, l }: { caseId: string; l: Record<string, string> }) {
  const [s, a, p] = useActionState(createQuotation, undefined);
  return (
    <form action={a} noValidate>
      <input type="hidden" name="case_id" value={caseId} />
      <label htmlFor="currency">{l.currency}</label><input id="currency" name="currency" required minLength={3} maxLength={3} dir="ltr" placeholder="ISO 4217" />
      <label htmlFor="tax_rate">{l.taxRate}</label><input id="tax_rate" name="tax_rate" type="number" step="0.01" min="0" max="100" required dir="ltr" />
      {s?.error && <p role="alert" className="error">{l[`err_${s.error}`]}</p>}
      <p><button type="submit" disabled={p}>{l.save}</button></p>
    </form>
  );
}
