import type { ReactNode } from "react";
import { signOut } from "@/app/actions";
import { LocaleSwitch } from "./LocaleSwitch";
import { t, type Locale } from "@/lib/i18n";
import type { AppRole } from "@/lib/rbac";

// Nav links are a convenience; every destination re-checks access server-side.
export function Shell({ locale, role, children }: { locale: Locale; role?: AppRole; children: ReactNode }) {
  const staff = role === undefined || role === "admin" || role === "management";
  return (
    <>
      <header className="bar">
        <nav aria-label="main" style={{ display: "flex", gap: "1rem", alignItems: "center", flexWrap: "wrap" }}>
          <strong>{t(locale, "appName")}</strong>
          <a href="/dashboard">{t(locale, "dashboard")}</a>
          {staff && <a href="/management/patients">{t(locale, "patients")}</a>}
          {staff && <a href="/management/doctors">{t(locale, "doctors")}</a>}
          {staff && <a href="/management/referrals">{t(locale, "referrals")}</a>}
          {staff && <a href="/management/cases">{t(locale, "cases")}</a>}
          {staff && <a href="/management/catalog">{t(locale, "catalog")}</a>}
          {staff && <a href="/management/reports">{t(locale, "reports")}</a>}
          {staff && <a href="/management/inventory">{t(locale, "inventory")}</a>}
          {staff && <a href="/management/procurement">{t(locale, "procurement")}</a>}
          {staff && <a href="/management/finance">{t(locale, "finance")}</a>}
          {staff && <a href="/management/appointments">{t(locale, "appointments")}</a>}
          {(role === "technician" || role === "admin") && <a href="/technician">{t(locale, "myCases")}</a>}
          {(role === "doctor" || role === "admin") && <a href="/doctor">{t(locale, "myPatients")}</a>}
          {(role === "patient") && <a href="/patient">{t(locale, "myCases")}</a>}
        </nav>
        <span style={{ display: "flex", gap: "1rem", alignItems: "center" }}>
          <LocaleSwitch locale={locale} />
          <form action={signOut}><button className="link" type="submit">{t(locale, "signOut")}</button></form>
        </span>
      </header>
      <main>{children}</main>
    </>
  );
}
