import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t, type MessageKey } from "@/lib/i18n";
import { isAppRole } from "@/lib/rbac";
import { Shell } from "@/components/Shell";
import { signOutEverywhere } from "./actions";

export default async function ProfilePage() {
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data: p } = await supabase.from("profiles").select("email,full_name,role,is_active").eq("id", user.id).maybeSingle();
  if (!p || !isAppRole(p.role)) redirect("/pending");
  return (
    <Shell locale={locale} role={p.role}>
      <div className="card">
        <h1>{t(locale, "gm_profile")}</h1>
        <dl>
          <dt>{t(locale, "email")}</dt><dd dir="ltr">{p.email}</dd>
          <dt>{t(locale, "role")}</dt><dd>{t(locale, `role_${p.role}` as MessageKey)}</dd>
          <dt>{t(locale, "status")}</dt><dd>{t(locale, p.is_active ? "active" : "inactive")}</dd>
          <dt>{t(locale, "gm_lastSignIn")}</dt><dd className="mono" dir="ltr">{user.last_sign_in_at ? new Date(user.last_sign_in_at).toISOString().slice(0, 16).replace("T", " ") : "—"}</dd>
        </dl>
        <p><a className="btn" href="/forgot">{t(locale, "gm_changePassword")}</a></p>
        <form action={signOutEverywhere}><button type="submit">{t(locale, "gm_signOutAll")}</button></form>
        <p><small>{t(locale, "gm_mfaNote")}</small></p>
      </div>
    </Shell>
  );
}
