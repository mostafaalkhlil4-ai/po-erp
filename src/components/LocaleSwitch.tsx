import { setLocale } from "@/app/actions";
import { t, type Locale } from "@/lib/i18n";

export function LocaleSwitch({ locale }: { locale: Locale }) {
  const next: Locale = locale === "ar" ? "en" : "ar";
  return (
    <form action={setLocale}>
      <input type="hidden" name="locale" value={next} />
      <button className="link" type="submit" lang={next}>{t(locale, "switchLang")}</button>
    </form>
  );
}
