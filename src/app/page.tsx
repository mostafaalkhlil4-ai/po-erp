import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { LocaleSwitch } from "@/components/LocaleSwitch";
import { isBackendConfigured, backendProblems } from "@/lib/env";
import { isDemoEnabled } from "@/lib/demo";

// Public landing page. No invented company or service claims: only the product name and the approved manufacturer list (D-002).
export default async function Home() {
  const locale = await getLocale();
  const configured = isBackendConfigured();
  const user = configured ? (await (await createClient()).auth.getUser()).data.user : null;
  return (
    <>
      <header className="bar"><strong>{t(locale, "appName")}</strong><LocaleSwitch locale={locale} /></header>
      <main>
        <div className="card">
          <h1>{t(locale, "appName")}</h1>
          <p>{t(locale, "landingTagline")}</p>
          {configured
            ? <p><a className="btn" href={user ? "/dashboard" : "/login"}>{user ? t(locale, "dashboard") : t(locale, "signIn")}</a></p>
            : <p role="status">{t(locale, "backendNotConfigured")} <code dir="ltr">{backendProblems().join(", ")}</code></p>}
          {!configured && isDemoEnabled() && <p><a className="btn" href="/demo">{locale === "ar" ? "عرض تجريبي (بيانات وهمية)" : "Demo preview (synthetic data)"}</a></p>}
          <h2>{t(locale, "approvedManufacturers")}</h2>
          <ul><li>Össur</li><li>Ottobock</li><li>PROTEOR</li></ul>
        </div>
      </main>
    </>
  );
}
