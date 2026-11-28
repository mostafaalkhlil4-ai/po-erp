import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";

const SENSITIVE = new Set(["invoices", "payments", "expenses", "quotations", "patient_visibility", "purchase_orders"]);

// Read-only view of audit_logs (audit.read = admin). The table is append-only at the database level.
export default async function AuditPage() {
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: allowed } = await supabase.rpc("has_permission", { p_code: "audit.read" });
  if (allowed !== true) redirect("/dashboard");
  const dayStart = new Date(); dayStart.setUTCHours(0, 0, 0, 0);
  const [{ data: logs }, { count: today }] = await Promise.all([
    supabase.from("audit_logs").select("id,actor_id,action,entity_type,entity_id,created_at").order("id", { ascending: false }).limit(200),
    supabase.from("audit_logs").select("id", { count: "exact", head: true }).gte("created_at", dayStart.toISOString()),
  ]);
  const rows = logs ?? [];
  const ids = [...new Set(rows.map((r) => r.actor_id).filter((x): x is string => !!x))];
  const { data: ps } = ids.length ? await supabase.from("profiles").select("id,email").in("id", ids) : { data: [] };
  const actors = new Map((ps ?? []).map((p: { id: string; email: string }) => [p.id, p.email]));
  const perm = rows.filter((r) => r.entity_type === "role_permissions" || r.entity_type === "profiles").length;
  const sens = rows.filter((r) => SENSITIVE.has(r.entity_type)).length;
  return (
    <Shell locale={locale} role="admin">
      <div className="card">
        <h1>{t(locale, "gm_audit")}</h1>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(11rem,1fr))", gap: "1rem" }}>
          <div><small>{t(locale, "gm_eventsToday")}</small><div className="mono" style={{ fontSize: "1.6rem" }} dir="ltr">{today ?? 0}</div></div>
          <div><small>{t(locale, "gm_permChanges")} ({t(locale, "gm_last200")})</small><div className="mono" style={{ fontSize: "1.6rem" }} dir="ltr">{perm}</div></div>
          <div><small>{t(locale, "gm_sensitiveOps")} ({t(locale, "gm_last200")})</small><div className="mono" style={{ fontSize: "1.6rem" }} dir="ltr">{sens}</div></div>
        </div>
      </div>
      <div className="card">
        <h2>{t(locale, "gm_last200")}</h2>
        {rows.length === 0 ? <p>{t(locale, "gm_noAudit")}</p> : (
          <table>
            <thead><tr><th scope="col">{t(locale, "gm_time")}</th><th scope="col">{t(locale, "gm_actor")}</th><th scope="col">{t(locale, "gm_action")}</th><th scope="col">{t(locale, "gm_entity")}</th></tr></thead>
            <tbody>{rows.map((r) => (
              <tr key={r.id}><td className="mono" dir="ltr">{new Date(r.created_at).toISOString().slice(0, 19).replace("T", " ")}</td>
                <td dir="ltr">{r.actor_id ? actors.get(r.actor_id) ?? "—" : "system"}</td><td dir="ltr">{r.action}</td>
                <td dir="ltr">{r.entity_type}{r.entity_id ? ` · ${r.entity_id.slice(0, 8)}` : ""}</td></tr>))}</tbody>
          </table>
        )}
        <p><small>{t(locale, "gm_auditPolicy")}</small></p>
      </div>
    </Shell>
  );
}
