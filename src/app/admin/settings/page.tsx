import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";
import { SettingsForm } from "./SettingsForm";

export default async function SettingsPage() {
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: allowed } = await supabase.rpc("has_permission", { p_code: "settings.manage" });
  if (allowed !== true) redirect("/dashboard");
  const { data: s } = await supabase.from("org_settings").select("center_name,phone,email,address,updated_at").maybeSingle();
  const l = {
    center_name: t(locale, "gm_centerName"), phone: t(locale, "gm_phone"), email: t(locale, "email"), address: t(locale, "gm_address"),
    save: t(locale, "save"), saved: t(locale, "saved"), err_invalid: t(locale, "invalidInput"), err_forbidden: t(locale, "errForbidden"), err_failed: t(locale, "errFailed"),
  };
  return (
    <Shell locale={locale} role="admin">
      <div className="card">
        <h1>{t(locale, "gm_settings")}</h1>
        <p><small>{t(locale, "gm_settingsNote")}</small></p>
        <SettingsForm l={l} init={{ center_name: s?.center_name ?? "", phone: s?.phone ?? "", email: s?.email ?? "", address: s?.address ?? "" }} />
        {s?.updated_at && <p><small>{t(locale, "gm_updatedAt")}: <span dir="ltr">{new Date(s.updated_at).toISOString().slice(0, 16).replace("T", " ")}</span></small></p>}
      </div>
      <div className="card"><h2>{t(locale, "gm_notBuilt")}</h2><p>{t(locale, "gm_settingsPending")}</p></div>
    </Shell>
  );
}
