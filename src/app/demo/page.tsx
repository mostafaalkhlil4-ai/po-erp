import { notFound } from "next/navigation";
import { getLocale } from "@/lib/locale";
import { LocaleSwitch } from "@/components/LocaleSwitch";
import { isDemoEnabled, ROLES } from "@/lib/demo";

export default async function DemoHome() {
  if (!isDemoEnabled()) notFound();
  const locale = await getLocale();
  const ar = locale === "ar";
  const names: Record<string, string> = ar
    ? { admin: "مدير النظام", management: "الإدارة", technician: "فني", doctor: "طبيب", patient: "مريض" }
    : { admin: "Admin", management: "Management", technician: "Technician", doctor: "Doctor", patient: "Patient" };
  return (
    <>
      <header className="bar"><strong>{ar ? "نظام الأطراف الاصطناعية والتقويم" : "P&O ERP"}</strong><LocaleSwitch locale={locale} /></header>
      <main>
        <div className="card">
          <p role="status"><strong>{ar ? "وضع تجريبي" : "Demo mode"}</strong> — {ar
            ? "بيانات وهمية للعرض فقط. لا توجد قاعدة بيانات ولا تسجيل دخول فعلي، ولا يُحفظ شيء."
            : "Synthetic data for viewing only. No database, no real sign-in, nothing is saved."}</p>
          <h1>{ar ? "اختر دوراً لاستعراض واجهته" : "Pick a role to preview its screens"}</h1>
          <ul>{ROLES.map((r) => <li key={r}><a className="btn" href={`/demo/${r}`}>{names[r]}</a></li>)}</ul>
        </div>
      </main>
    </>
  );
}
