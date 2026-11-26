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
      <head>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="" />
        <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@500&family=Noto+Kufi+Arabic:wght@700;800&family=Noto+Sans+Arabic:wght@400;500;600&family=Plus+Jakarta+Sans:wght@600;800&display=swap" />
      </head>
      <body>{children}</body>
    </html>
  );
}
