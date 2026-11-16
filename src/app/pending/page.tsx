import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { signOut } from "@/app/actions";

export default async function PendingPage() {
  const locale = await getLocale();
  return (
    <main>
      <div className="card" style={{ maxWidth: "30rem", margin: "4rem auto" }}>
        <h1>{t(locale, "pendingTitle")}</h1>
        <p>{t(locale, "pendingBody")}</p>
        <form action={signOut}><button type="submit">{t(locale, "signOut")}</button></form>
      </div>
    </main>
  );
}
