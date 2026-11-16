import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { ResetForm } from "./ResetForm";
export default async function Reset() {
  const l = await getLocale();
  return (<main><div className="card" style={{ maxWidth: "26rem", margin: "4rem auto" }}>
    <h1>{t(l, "newPassword")}</h1>
    <ResetForm labels={{ password: t(l, "newPassword"), submit: t(l, "updatePassword"), error: t(l, "invalidInput") }} />
  </div></main>);
}
