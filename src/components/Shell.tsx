import type { ReactNode } from "react";
import { signOut } from "@/app/actions";
import { LocaleSwitch } from "./LocaleSwitch";
import { t, type Locale } from "@/lib/i18n";
import type { AppRole } from "@/lib/rbac";
import { NavLink } from "./NavLink";
import { createClient } from "@/lib/supabase/server";
import { isAppRole } from "@/lib/rbac";

// Nav links are a convenience; every destination re-checks access server-side.
export async function Shell({ locale, role: hint, children }: { locale: Locale; role?: AppRole; children: ReactNode }) {
  // Pages pass a hint; the sidebar uses the signed-in user's real role so an admin keeps the admin links everywhere.
  let role = hint;
  try {
    const supabase = await createClient();
    const { data: { user } } = await supabase.auth.getUser();
    if (user) {
      const { data: p } = await supabase.from("profiles").select("role").eq("id", user.id).maybeSingle();
      if (p && isAppRole(p.role)) role = p.role;
    }
  } catch { /* keep the hint; routes are still protected by proxy.ts and RLS */ }
  const staff = role === undefined || role === "admin" || role === "management";
  return (
    <div className="app">
      <aside className="side">
        <div className="brand">Ottobonm.</div>
        <nav aria-label="main">
          <NavLink href="/dashboard">{t(locale, "dashboard")}</NavLink>
          {staff && <NavLink href="/management/patients">{t(locale, "patients")}</NavLink>}
          {staff && <NavLink href="/management/cases">{t(locale, "cases")}</NavLink>}
          {staff && <NavLink href="/management/appointments">{t(locale, "appointments")}</NavLink>}
          {staff && <NavLink href="/management/doctors">{t(locale, "doctors")}</NavLink>}
          {staff && <NavLink href="/management/referrals">{t(locale, "referrals")}</NavLink>}
          {staff && <NavLink href="/management/technicians">{t(locale, "technicians")}</NavLink>}
          {staff && <NavLink href="/management/catalog">{t(locale, "catalog")}</NavLink>}
          {staff && <NavLink href="/management/quotations">{t(locale, "gm_quotations")}</NavLink>}
          {staff && <NavLink href="/management/inventory">{t(locale, "inventory")}</NavLink>}
          {staff && <NavLink href="/management/procurement">{t(locale, "procurement")}</NavLink>}
          {staff && <NavLink href="/management/finance">{t(locale, "finance")}</NavLink>}
          {staff && <NavLink href="/management/reports">{t(locale, "reports")}</NavLink>}
          {role === "admin" && <NavLink href="/admin/users">{t(locale, "users")}</NavLink>}
          {role === "admin" && <NavLink href="/admin/audit">{t(locale, "gm_audit")}</NavLink>}
          {role === "admin" && <NavLink href="/admin/settings">{t(locale, "gm_settings")}</NavLink>}
          {role === "admin" && <NavLink href="/admin/profile">{t(locale, "gm_profile")}</NavLink>}
          {(role === "technician" || role === "admin") && <NavLink href="/technician">{t(locale, "myCases")}</NavLink>}
          {(role === "doctor" || role === "admin") && <NavLink href="/doctor">{t(locale, "myPatients")}</NavLink>}
          {(role === "patient") && <NavLink href="/patient">{t(locale, "myCases")}</NavLink>}
        </nav>
        <span className="tools">
          <LocaleSwitch locale={locale} />
          <form action={signOut}><button className="link" type="submit">{t(locale, "signOut")}</button></form>
        </span>
      </aside>
      <div className="content"><main>{children}</main></div>
    </div>
  );
}
