import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";
import { countBy, sumByCurrency, outstandingByCurrency } from "@/lib/report";

// Real data only, computed under the viewer's RLS: sections the user may not read simply stay empty or hidden.
export default async function ReportsPage() {
  const locale = await getLocale();
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const week = new Date(Date.now() + 7 * 86400000).toISOString();
  const [{ data: canOps }, { data: canFin }, { data: canInv }] = await Promise.all([
    supabase.rpc("has_permission", { p_code: "reports.operational" }),
    supabase.rpc("has_permission", { p_code: "finance.manage" }),
    supabase.rpc("has_permission", { p_code: "inventory.manage" }),
  ]);
  if (canOps !== true) return <Shell locale={locale} role="management"><div className="card"><p>{t(locale, "errForbidden")}</p></div></Shell>;
  const [{ data: cases }, { count: upcoming }, { count: overdue }, { count: awaiting }, { data: items }, { data: levels }] = await Promise.all([
    supabase.from("cases").select("status").limit(20000),
    supabase.from("appointments").select("id", { count: "exact", head: true }).eq("status", "scheduled").gte("scheduled_at", new Date().toISOString()).lte("scheduled_at", week),
    supabase.from("follow_ups").select("id", { count: "exact", head: true }).eq("status", "planned").lt("due_date", today),
    supabase.from("quotations").select("id", { count: "exact", head: true }).eq("status", "submitted"),
    canInv === true ? supabase.from("inventory_items").select("id,name,unit,min_stock").eq("is_active", true) : Promise.resolve({ data: [] }),
    canInv === true ? supabase.rpc("stock_levels") : Promise.resolve({ data: [] }),
  ]);
  const byStatus = countBy(cases ?? [], (c) => c.status);
  const lv = new Map<string, number>((levels ?? []).map((x: { item_id: string; on_hand: number }) => [x.item_id, Number(x.on_hand)]));
  const low = (items ?? []).filter((i: { id: string; min_stock: number }) => (lv.get(i.id) ?? 0) < Number(i.min_stock));
  let fin: ReturnType<typeof outstandingByCurrency> = {}; let exp: Record<string, number> = {};
  if (canFin === true) {
    const [{ data: invs }, { data: pays }, { data: exps }] = await Promise.all([
      supabase.from("invoices").select("id,currency,amount,status").limit(20000),
      supabase.from("payments").select("invoice_id,amount").limit(50000),
      supabase.from("expenses").select("currency,amount").limit(50000),
    ]);
    fin = outstandingByCurrency(invs ?? [], pays ?? []);
    exp = sumByCurrency(exps ?? [], (e) => e.currency, (e) => e.amount);
  }
  return (
    <Shell locale={locale} role="management">
      <div className="card">
        <h1>{t(locale, "reports")}</h1>
        <h2>{t(locale, "cases")}</h2>
        <table style={{ width: "100%", borderCollapse: "collapse" }}><tbody>
          {Object.entries(byStatus).map(([s, n]) => <tr key={s}><th scope="row">{t(locale, `st_${s}` as never)}</th><td dir="ltr">{n}</td></tr>)}
        </tbody></table>
        {Object.keys(byStatus).length === 0 && <p>{t(locale, "noResults")}</p>}
        <h2>{t(locale, "attention")}</h2>
        <ul>
          <li>{t(locale, "upcomingAppointments")}: <strong dir="ltr">{upcoming ?? 0}</strong></li>
          <li>{t(locale, "overdueFollowUps")}: <strong dir="ltr">{overdue ?? 0}</strong></li>
          <li>{t(locale, "quotationsAwaiting")}: <strong dir="ltr">{awaiting ?? 0}</strong></li>
          {canInv === true && <li>{t(locale, "lowStock")}: <strong dir="ltr">{low.length}</strong>{low.length > 0 && <> — {low.map((i: { name: string }) => i.name).join("، ")}</>}</li>}
        </ul>
      </div>
      {canFin === true && <div className="card" style={{ marginTop: "1rem" }}>
        <h2>{t(locale, "finance")}</h2>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead><tr><th scope="col">{t(locale, "currency")}</th><th scope="col">{t(locale, "invoiced")}</th><th scope="col">{t(locale, "paid")}</th><th scope="col">{t(locale, "outstanding")}</th><th scope="col">{t(locale, "expenses")}</th></tr></thead>
          <tbody>{[...new Set([...Object.keys(fin), ...Object.keys(exp)])].sort().map((cur) => (
            <tr key={cur}><th scope="row" dir="ltr">{cur}</th><td dir="ltr">{fin[cur]?.invoiced ?? 0}</td><td dir="ltr">{fin[cur]?.paid ?? 0}</td><td dir="ltr">{fin[cur]?.outstanding ?? 0}</td><td dir="ltr">{exp[cur] ?? 0}</td></tr>))}</tbody>
        </table>
        <p><small>{t(locale, "perCurrencyNote")}</small></p>
      </div>}
    </Shell>
  );
}
