// Pure aggregation helpers for reports. Money is summed in integer cents (never floats) and never across currencies.
export function countBy<T>(rows: readonly T[], key: (r: T) => string): Record<string, number> {
  const out: Record<string, number> = {};
  for (const r of rows) out[key(r)] = (out[key(r)] ?? 0) + 1;
  return out;
}
const cents = (v: number | string) => Math.round(Number(v) * 100);
export function sumByCurrency<T>(rows: readonly T[], currency: (r: T) => string, amount: (r: T) => number | string): Record<string, number> {
  const c: Record<string, number> = {};
  for (const r of rows) c[currency(r)] = (c[currency(r)] ?? 0) + cents(amount(r));
  return Object.fromEntries(Object.entries(c).map(([k, v]) => [k, v / 100]));
}
export function outstandingByCurrency(
  invoices: readonly { id: string; currency: string; amount: number | string; status: string }[],
  payments: readonly { invoice_id: string; amount: number | string }[],
): Record<string, { invoiced: number; paid: number; outstanding: number }> {
  const issued = invoices.filter((i) => i.status === "issued");
  const ids = new Map(issued.map((i) => [i.id, i.currency]));
  const inv = sumByCurrency(issued, (i) => i.currency, (i) => i.amount);
  const paid = sumByCurrency(payments.filter((p) => ids.has(p.invoice_id)), (p) => ids.get(p.invoice_id)!, (p) => p.amount);
  const out: Record<string, { invoiced: number; paid: number; outstanding: number }> = {};
  for (const cur of Object.keys(inv)) {
    const p = paid[cur] ?? 0;
    out[cur] = { invoiced: inv[cur], paid: p, outstanding: Math.round((inv[cur] - p) * 100) / 100 };
  }
  return out;
}
