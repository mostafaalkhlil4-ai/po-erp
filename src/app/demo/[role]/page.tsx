import { notFound } from "next/navigation";
import { getLocale } from "@/lib/locale";
import { LocaleSwitch } from "@/components/LocaleSwitch";
import { DEMO_SECTIONS, demoRows, isAppRole, isDemoEnabled } from "@/lib/demo";

export default async function DemoRole({ params }: { params: Promise<{ role: string }> }) {
  const { role } = await params;
  if (!isDemoEnabled() || !isAppRole(role)) notFound();
  const locale = await getLocale();
  const ar = locale === "ar";
  const L = (a: string, e: string) => (ar ? a : e);
  const sections = DEMO_SECTIONS[role];
  const { patients, cases } = demoRows(role);
  const status: Record<string, string> = ar
    ? { assessment: "تقييم", production: "إنتاج", fitting: "تركيب" }
    : { assessment: "Assessment", production: "Production", fitting: "Fitting" };
  const empty = (a: string, e: string) => <p>{L(a, e)}</p>;
  return (
    <>
      <header className="bar"><strong>{L("وضع تجريبي", "Demo mode")} — {role}</strong><LocaleSwitch locale={locale} /></header>
      <main>
        <p role="status">{L("بيانات وهمية للعرض فقط؛ لا يُحفظ شيء.", "Synthetic data for viewing only; nothing is saved.")} <a href="/demo">{L("تغيير الدور", "Change role")}</a></p>
        {sections.includes("users") && <section className="card"><h2>{L("المستخدمون", "Users")}</h2>{empty("إدارة الحسابات والأدوار تتطلب قاعدة بيانات فعلية.", "Account and role management needs a real database.")}</section>}
        {sections.includes("patients") && <section className="card"><h2>{L("المرضى", "Patients")}</h2>
          <table><thead><tr><th>ID</th><th>{L("الاسم", "Name")}</th></tr></thead>
            <tbody>{patients.map((p) => <tr key={p.id}><td>{p.id}</td><td>{p.name[locale]}</td></tr>)}</tbody></table></section>}
        {sections.includes("cases") && <section className="card"><h2>{L("الحالات", "Cases")}</h2>
          <table><thead><tr><th>ID</th><th>{L("المريض", "Patient")}</th><th>{L("المرحلة", "Stage")}</th></tr></thead>
            <tbody>{cases.map((c) => <tr key={c.id}><td>{c.id}</td><td>{c.patient}</td><td>{status[c.status]}</td></tr>)}</tbody></table></section>}
        {sections.includes("catalog") && <section className="card"><h2>{L("الكتالوج", "Catalog")}</h2>
          <p>Össur · Ottobock · PROTEOR</p>{empty("الكتالوج فارغ؛ تُضاف المنتجات والأسعار يدوياً.", "The catalog is empty; products and prices are added manually.")}</section>}
        {sections.includes("inventory") && <section className="card"><h2>{L("المخزون", "Inventory")}</h2>{empty("لا مواد؛ تُدخل الإدارة المخزون يدوياً.", "No items; Management enters inventory manually.")}</section>}
        {sections.includes("finance") && <section className="card"><h2>{L("المالية", "Finance")}</h2>{empty("العملة والضريبة والقواعد المالية تُدخل يدوياً. لا أرقام في العرض التجريبي.", "Currency, tax and financial rules are entered manually. No figures in the demo.")}</section>}
      </main>
    </>
  );
}
