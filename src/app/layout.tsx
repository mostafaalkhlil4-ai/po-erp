import type { ReactNode } from "react";
import "./globals.css";
import { dirOf, t } from "@/lib/i18n";
import { getLocale } from "@/lib/locale";

export async function generateMetadata() {
  return { title: t(await getLocale(), "appName") };
}

export default async function RootLayout({ children }: { children: ReactNode }) {
  const locale = await getLocale();
  return (
    <html lang={locale} dir={dirOf(locale)}>
      <body>{children}</body>
    </html>
  );
}
