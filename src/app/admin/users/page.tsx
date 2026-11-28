import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t, type MessageKey } from "@/lib/i18n";
import { ROLES } from "@/lib/rbac";
import { Shell } from "@/components/Shell";
import { updateUser } from "./actions";

export default async function UsersPage() {
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: allowed } = await supabase.rpc("has_permission", { p_code: "users.manage" });
  if (allowed !== true) redirect("/dashboard");

  const { data: users } = await supabase
    .from("profiles").select("id,email,full_name,role,is_active").order("created_at");

  const { data: grants } = await supabase.from("role_permissions").select("role,permission_code").limit(2000);
  const codes = [...new Set((grants ?? []).map((g) => g.permission_code))].sort();
  const has = new Set((grants ?? []).map((g) => `${g.role}|${g.permission_code}`));
  return (
    <Shell locale={locale} role="admin">
      <div className="card">
        <h1>{t(locale, "users")}</h1>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <caption className="sr-only">{t(locale, "users")}</caption>
          <thead><tr>
            <th scope="col">{t(locale, "email")}</th>
            <th scope="col">{t(locale, "role")}</th>
            <th scope="col">{t(locale, "status")}</th>
            <th scope="col"><span className="sr-only">{t(locale, "save")}</span></th>
          </tr></thead>
          <tbody>
            {(users ?? []).map((u) => (
              <tr key={u.id}>
                <td dir="ltr">{u.email}<br /><small>{u.full_name}</small></td>
                <td colSpan={3}>
                  <form action={updateUser} style={{ display: "flex", gap: ".5rem", alignItems: "center" }}>
                    <input type="hidden" name="id" value={u.id} />
                    <select name="role" defaultValue={u.role} aria-label={t(locale, "role")}>
                      {ROLES.map((r) => <option key={r} value={r}>{t(locale, `role_${r}` as MessageKey)}</option>)}
                    </select>
                    <select name="is_active" defaultValue={String(u.is_active)} aria-label={t(locale, "status")}>
                      <option value="true">{t(locale, "active")}</option>
                      <option value="false">{t(locale, "inactive")}</option>
                    </select>
                    <button type="submit">{t(locale, "save")}</button>
                  </form>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {codes.length > 0 && (
        <div className="card">
          <h2>{t(locale, "gm_matrix")}</h2>
          <table>
            <thead><tr><th scope="col">{t(locale, "gm_permission")}</th>{ROLES.map((r) => <th key={r} scope="col">{t(locale, `role_${r}` as MessageKey)}</th>)}</tr></thead>
            <tbody>{codes.map((c) => (
              <tr key={c}><th scope="row" className="mono" dir="ltr" style={{ fontWeight: 500 }}>{c}</th>
                {ROLES.map((r) => <td key={r} aria-label={has.has(`${r}|${c}`) ? "yes" : "no"}>{has.has(`${r}|${c}`) ? "✓" : "—"}</td>)}</tr>))}</tbody>
          </table>
          <p><small>{t(locale, "gm_matrixNote")}</small></p>
        </div>
      )}
    </Shell>
  );
}
