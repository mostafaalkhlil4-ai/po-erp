import { describe, it, expect } from "vitest";
import { countBy, sumByCurrency, outstandingByCurrency } from "@/lib/report";

describe("report helpers", () => {
  it("counts by key", () => {
    expect(countBy([{ s: "a" }, { s: "b" }, { s: "a" }], (r) => r.s)).toEqual({ a: 2, b: 1 });
    expect(countBy([], () => "x")).toEqual({});
  });
  it("sums per currency without float drift and never mixes currencies", () => {
    const rows = [{ c: "USD", a: "0.1" }, { c: "USD", a: "0.2" }, { c: "EUR", a: 5 }];
    expect(sumByCurrency(rows, (r) => r.c, (r) => r.a)).toEqual({ USD: 0.3, EUR: 5 });
  });
  it("outstanding ignores void invoices and their payments, per currency", () => {
    const inv = [
      { id: "1", currency: "USD", amount: "100.00", status: "issued" },
      { id: "2", currency: "USD", amount: "50.00", status: "void" },
      { id: "3", currency: "EUR", amount: "80.00", status: "issued" },
    ];
    const pay = [{ invoice_id: "1", amount: "40.10" }, { invoice_id: "3", amount: "80" }, { invoice_id: "2", amount: "1" }];
    expect(outstandingByCurrency(inv, pay)).toEqual({
      USD: { invoiced: 100, paid: 40.1, outstanding: 59.9 },
      EUR: { invoiced: 80, paid: 80, outstanding: 0 },
    });
  });
});
