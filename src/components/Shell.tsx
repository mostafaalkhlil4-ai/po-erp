import type { ReactNode } from "react";
import { signOut } from "@/app/actions";
import { LocaleSwitch } from "./LocaleSwitch";
import { t, type Locale } from "@/lib/i18n";
import type { AppRole } from "@/lib/rbac";
import { NavLink } from "./NavLink";

// Nav links are a convenience; every destination re-checks access server-side.
export function Shell({ locale, role, children }: { locale: Locale; role?: AppRole; children: ReactNode }) {
  const staff = role === undefined || role === "admin" || role === "management";
  return (
    <div className="app">
      <aside className="side">
        <div className="brand">Ottobonm.</div>
        <nav aria-label="main">
          <NavLink href="/dashboard">{t(locale, "dashboard")}</NavLink>
          {staff && <NavLink href="/management/patients">{t(locale, "patients")}</NavLink>}
          {staff && <NavLink href="/management/doctors">{t(locale, "doctors")}</NavLink>}
          {staff && <NavLink href="/management/referrals">{t(locale, "referrals")}</NavLink>}
          {staff && <NavLink href="/management/cases">{t(locale, "cases")}</NavLink>}
          {staff && <NavLink href="/management/catalog">{t(locale, "catalog")}</NavLink>}
          {staff && <NavLink href="/management/reports">{t(locale, "reports")}</NavLink>}
          {staff && <NavLink href="/management/inventory">{t(locale, "inventory")}</NavLink>}
          {staff && <NavLink href="/management/procurement">{t(locale, "procurement")}</NavLink>}
          {staff && <NavLink href="/management/finance">{t(locale, "finance")}</NavLink>}
          {staff && <NavLink href="/management/appointments">{t(locale, "appointments")}</NavLink>}
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
