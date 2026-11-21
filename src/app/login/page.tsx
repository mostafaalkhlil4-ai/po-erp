import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { LocaleSwitch } from "@/components/LocaleSwitch";
import { LoginForm } from "./LoginForm";
import { isBackendConfigured } from "@/lib/env";

export default async function LoginPage() {
  const locale = await getLocale();
  return (
    <main>
      <div className="card" style={{ maxWidth: "26rem", margin: "4rem auto" }}>
        <h1>{t(locale, "appName")}</h1>
        {!isBackendConfigured() ? <p role="status">{t(locale, "backendNotConfigured")}</p> : <><LoginForm labels={{
          email: t(locale, "email"), password: t(locale, "password"), submit: t(locale, "signIn"),
          invalidInput: t(locale, "invalidInput"), invalidCredentials: t(locale, "invalidCredentials"),
        }} />
        <p><a href="/forgot">{t(locale, "forgotPassword")}</a></p></>}
        <p><LocaleSwitch locale={locale} /></p>
      </div>
    </main>
  );
}
