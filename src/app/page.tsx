import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { LocaleSwitch } from "@/components/LocaleSwitch";

// Public landing page. No invented company or service claims: only the product name and the approved manufacturer list (D-002).
export default async function Home() {
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  return (
    <>
      <header className="bar"><strong>{t(locale, "appName")}</strong><LocaleSwitch locale={locale} /></header>
      <main>
        <div className="card">
          <h1>{t(locale, "appName")}</h1>
          <p>{t(locale, "landingTagline")}</p>
          <p><a className="btn" href={user ? "/dashboard" : "/login"}>{user ? t(locale, "dashboard") : t(locale, "signIn")}</a></p>
          <h2>{t(locale, "approvedManufacturers")}</h2>
          <ul><li>Össur</li><li>Ottobock</li><li>PROTEOR</li></ul>
        </div>
      </main>
    </>
  );
}
