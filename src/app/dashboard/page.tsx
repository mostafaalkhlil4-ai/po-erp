import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t, type MessageKey } from "@/lib/i18n";
import { isAppRole } from "@/lib/rbac";
import { Shell } from "@/components/Shell";
import { sumByCurrency } from "@/lib/report";

// Real data only, under the viewer's RLS. No sample figures: what the user may not read shows as zero/hidden.
export default async function Dashboard() {
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: profile } = await supabase
    .from("profiles").select("full_name,email,role,is_active").eq("id", user.id).maybeSingle();
  if (!profile || !profile.is_active || !isAppRole(profile.role)) redirect("/pending");
  const role = profile.role;
  const staff = role === "admin" || role === "management";

  const { data: perms } = await supabase
    .from("role_permissions").select("permission_code").eq("role", role).order("permission_code");

  let kpi: { patients: number; open: number; today: number; revenue: Record<string, number>; awaiting: number; low: number; overdue: number; canFin: boolean } | null = null;
  let recent: { id: number; actor_id: string | null; action: string; entity_type: string; entity_id: string | null; created_at: string }[] = [];
  let actors = new Map<string, string>();
  if (staff) {
    const now = new Date();
    const dayStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
    const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
    const [{ data: canFin }, { data: canInv }, { data: canAudit }] = await Promise.all([
      supabase.rpc("has_permission", { p_code: "finance.manage" }),
      supabase.rpc("has_permission", { p_code: "inventory.manage" }),
      supabase.rpc("has_permission", { p_code: "audit.read" }),
    ]);
    const today = now.toISOString().slice(0, 10);
    const [pat, open, appt, awaiting, overdue, items, levels, pays] = await Promise.all([
      supabase.from("patients").select("id", { count: "exact", head: true }).eq("is_archived", false),
      supabase.from("cases").select("id", { count: "exact", head: true }).not("status", "in", "(closed,cancelled)"),
      supabase.from("appointments").select("id", { count: "exact", head: true }).eq("status", "scheduled")
        .gte("scheduled_at", dayStart.toISOString()).lt("scheduled_at", new Date(dayStart.getTime() + 86400000).toISOString()),
      supabase.from("quotations").select("id", { count: "exact", head: true }).eq("status", "submitted"),
      supabase.from("follow_ups").select("id", { count: "exact", head: true }).eq("status", "planned").lt("due_date", today),
      canInv === true ? supabase.from("inventory_items").select("id,min_stock").eq("is_active", true) : Promise.resolve({ data: [] }),
      canInv === true ? supabase.rpc("stock_levels") : Promise.resolve({ data: [] }),
      canFin === true ? supabase.from("payments").select("amount,invoice_id,created_at").gte("created_at", monthStart.toISOString()).limit(50000) : Promise.resolve({ data: [] }),
    ]);
    const lv = new Map<string, number>((levels.data ?? []).map((x: { item_id: string; on_hand: number }) => [x.item_id, Number(x.on_hand)]));
    const low = (items.data ?? []).filter((i: { id: string; min_stock: number }) => (lv.get(i.id) ?? 0) < Number(i.min_stock)).length;
    let revenue: Record<string, number> = {};
    if (canFin === true && (pays.data ?? []).length > 0) {
      const ids = [...new Set((pays.data ?? []).map((p: { invoice_id: string }) => p.invoice_id))];
      const { data: invs } = await supabase.from("invoices").select("id,currency").in("id", ids);
      const cur = new Map((invs ?? []).map((i: { id: string; currency: string }) => [i.id, i.currency]));
      revenue = sumByCurrency(pays.data ?? [], (p: { invoice_id: string }) => cur.get(p.invoice_id) ?? "?", (p: { amount: number }) => p.amount);
    }
    kpi = { patients: pat.count ?? 0, open: open.count ?? 0, today: appt.count ?? 0, revenue, awaiting: awaiting.count ?? 0, low, overdue: overdue.count ?? 0, canFin: canFin === true };
    if (canAudit === true) {
      const { data: logs } = await supabase.from("audit_logs").select("id,actor_id,action,entity_type,entity_id,created_at").order("id", { ascending: false }).limit(8);
      recent = logs ?? [];
      const ids = [...new Set(recent.map((r) => r.actor_id).filter((x): x is string => !!x))];
      if (ids.length) {
        const { data: ps } = await supabase.from("profiles").select("id,email").in("id", ids);
        actors = new Map((ps ?? []).map((p: { id: string; email: string }) => [p.id, p.email]));
      }
    }
  }

  return (
    <Shell locale={locale} role={role}>
      <div className="card">
        <h1>{t(locale, "dashboard")}</h1>
        <p>{t(locale, "welcome")} {profile.full_name || profile.email} — {t(locale, `role_${role}` as MessageKey)}</p>
      </div>
      {kpi && (
        <>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(11rem,1fr))", gap: "1rem", marginBottom: "1rem" }}>
            <div className="card"><small>{t(locale, "gm_kpiPatients")}</small><div className="mono" style={{ fontSize: "1.8rem" }} dir="ltr">{kpi.patients}</div></div>
            <div className="card"><small>{t(locale, "gm_kpiOpenCases")}</small><div className="mono" style={{ fontSize: "1.8rem" }} dir="ltr">{kpi.open}</div></div>
            <div className="card"><small>{t(locale, "gm_kpiToday")}</small><div className="mono" style={{ fontSize: "1.8rem" }} dir="ltr">{kpi.today}</div></div>
            {kpi.canFin && <div className="card"><small>{t(locale, "gm_kpiRevenue")}</small>
              {Object.keys(kpi.revenue).length === 0 ? <div className="mono" style={{ fontSize: "1.8rem" }} dir="ltr">0</div>
                : Object.entries(kpi.revenue).map(([c, v]) => <div key={c} className="mono" style={{ fontSize: "1.3rem" }} dir="ltr">{v} {c}</div>)}</div>}
          </div>
          <div className="card">
            <h2>{t(locale, "gm_alerts")}</h2>
            <ul>
              {kpi.awaiting > 0 && <li><a href="/management/quotations">{t(locale, "gm_alertQuotations")}</a>: <strong dir="ltr">{kpi.awaiting}</strong></li>}
              {kpi.low > 0 && <li><a href="/management/inventory">{t(locale, "gm_alertLowStock")}</a>: <strong dir="ltr">{kpi.low}</strong></li>}
              {kpi.overdue > 0 && <li><a href="/management/reports">{t(locale, "gm_alertOverdue")}</a>: <strong dir="ltr">{kpi.overdue}</strong></li>}
              {kpi.awaiting + kpi.low + kpi.overdue === 0 && <li>{t(locale, "gm_noAlerts")}</li>}
            </ul>
          </div>
          {role === "admin" && (
            <div className="card">
              <h2>{t(locale, "gm_recent")}</h2>
              {recent.length === 0 ? <p>{t(locale, "gm_noAudit")}</p> : (
                <table>
                  <thead><tr><th scope="col">{t(locale, "gm_time")}</th><th scope="col">{t(locale, "gm_actor")}</th><th scope="col">{t(locale, "gm_action")}</th><th scope="col">{t(locale, "gm_entity")}</th></tr></thead>
                  <tbody>{recent.map((r) => (
                    <tr key={r.id}><td className="mono" dir="ltr">{new Date(r.created_at).toISOString().slice(0, 16).replace("T", " ")}</td>
                      <td dir="ltr">{r.actor_id ? actors.get(r.actor_id) ?? "—" : "system"}</td><td dir="ltr">{r.action}</td><td dir="ltr">{r.entity_type}</td></tr>))}</tbody>
                </table>
              )}
              <p><a href="/admin/audit">{t(locale, "gm_audit")}</a></p>
            </div>
          )}
        </>
      )}
      {!staff && (
        <div className="card">
          {role === "technician" && <p><a className="btn" href="/technician">{t(locale, "myCases")}</a></p>}
          {role === "doctor" && <p><a className="btn" href="/doctor">{t(locale, "myPatients")}</a></p>}
          {role === "patient" && <p><a className="btn" href="/patient">{t(locale, "myCases")}</a></p>}
        </div>
      )}
      <div className="card">
        <h2>{t(locale, "permissions")}</h2>
        <ul className="perms">{(perms ?? []).map((p) => <li key={p.permission_code} dir="ltr">{p.permission_code}</li>)}</ul>
      </div>
    </Shell>
  );
}
