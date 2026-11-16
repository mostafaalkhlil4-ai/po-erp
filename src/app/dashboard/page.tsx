import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t, type MessageKey } from "@/lib/i18n";
import { isAppRole } from "@/lib/rbac";
import { signOut } from "@/app/actions";
import { LocaleSwitch } from "@/components/LocaleSwitch";

// Real data only: profile and permissions come from the database under RLS.
export default async function Dashboard() {
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: profile } = await supabase
    .from("profiles").select("full_name,email,role,is_active").eq("id", user.id).maybeSingle();
  if (!profile || !profile.is_active || !isAppRole(profile.role)) redirect("/pending");

  const { data: perms } = await supabase
    .from("role_permissions").select("permission_code").eq("role", profile.role).order("permission_code");

  return (
    <>
      <header className="bar">
        <strong>{t(locale, "appName")}</strong>
        <span style={{ display: "flex", gap: "1rem", alignItems: "center" }}>
          <LocaleSwitch locale={locale} />
          <form action={signOut}><button className="link" type="submit">{t(locale, "signOut")}</button></form>
        </span>
      </header>
      <main>
        <div className="card">
          <h1>{t(locale, "dashboard")}</h1>
          <p>{t(locale, "welcome")} {profile.full_name || profile.email}</p>
          <p>{t(locale, "role")}: <strong>{t(locale, `role_${profile.role}` as MessageKey)}</strong></p>
          {(profile.role === "admin" || profile.role === "management") && <p><a className="btn" href="/management/patients">{t(locale, "patients")}</a> <a className="btn" href="/management/doctors">{t(locale, "doctors")}</a></p>}
          {(profile.role === "doctor" || profile.role === "admin") && <p><a className="btn" href="/doctor">{t(locale, "myPatients")}</a></p>}
          {profile.role === "patient" && <p><a className="btn" href="/patient">{t(locale, "myReports")}</a></p>}
          {profile.role === "admin" && <p><a className="btn" href="/admin/users">{t(locale, "manageUsers")}</a></p>}
          <h2>{t(locale, "permissions")}</h2>
          <ul className="perms">{(perms ?? []).map((p) => <li key={p.permission_code} dir="ltr">{p.permission_code}</li>)}</ul>
        </div>
      </main>
    </>
  );
}
