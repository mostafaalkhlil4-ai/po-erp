import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { ForgotForm } from "./ForgotForm";
export default async function Forgot() {
  const l = await getLocale();
  return (<main><div className="card" style={{ maxWidth: "26rem", margin: "4rem auto" }}>
    <h1>{t(l, "forgotPassword")}</h1>
    <ForgotForm labels={{ email: t(l, "email"), submit: t(l, "sendReset"), sent: t(l, "resetSent"), invalid: t(l, "invalidInput") }} />
  </div></main>);
}
