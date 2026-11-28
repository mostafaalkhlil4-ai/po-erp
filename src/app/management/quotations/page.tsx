import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t, type MessageKey } from "@/lib/i18n";
import { Shell } from "@/components/Shell";

// Real quotations only (prices come from the database; nothing is invented). Totals are computed by quotation_totals().
export default async function QuotationsList() {
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: allowed } = await supabase.rpc("has_permission", { p_code: "quotations.manage" });
  if (allowed !== true) redirect("/dashboard");
  const { data: qs } = await supabase.from("quotations")
    .select("id,quotation_no,case_id,revision,status,currency").order("quotation_no", { ascending: false }).limit(100);
  const caseIds = [...new Set((qs ?? []).map((q) => q.case_id))];
  const { data: cases } = caseIds.length ? await supabase.from("cases").select("id,case_no,patient_id").in("id", caseIds) : { data: [] };
  const pids = [...new Set((cases ?? []).map((c) => c.patient_id))];
  const { data: pats } = pids.length ? await supabase.from("patients").select("id,full_name").in("id", pids) : { data: [] };
  const caseMap = new Map((cases ?? []).map((c) => [c.id, c]));
  const pname = new Map((pats ?? []).map((p) => [p.id, p.full_name]));
  const totals = await Promise.all((qs ?? []).map(async (q) => {
    const { data } = await supabase.rpc("quotation_totals", { p_q: q.id });
    const row = Array.isArray(data) ? data[0] : data;
    return [q.id, row?.total as number | undefined] as const;
  }));
  const tot = new Map(totals);
  return (
    <Shell locale={locale} role="admin">
      <div className="card">
        <h1>{t(locale, "gm_quotations")}</h1>
        {(qs ?? []).length === 0 ? <p>{t(locale, "gm_qNone")}</p> : (
          <table>
            <thead><tr><th scope="col">{t(locale, "gm_qNo")}</th><th scope="col">{t(locale, "gm_qPatient")}</th><th scope="col">{t(locale, "gm_qCase")}</th>
              <th scope="col">{t(locale, "gm_qRev")}</th><th scope="col">{t(locale, "status")}</th><th scope="col">{t(locale, "gm_qTotal")}</th></tr></thead>
            <tbody>{(qs ?? []).map((q) => {
              const c = caseMap.get(q.case_id);
              return (
                <tr key={q.id}>
                  <td className="num" dir="ltr"><a href={`/management/quotations/${q.id}`}>QT-{q.quotation_no}</a></td>
                  <td>{c ? pname.get(c.patient_id) ?? "—" : "—"}</td>
                  <td className="num" dir="ltr">{c ? <a href={`/management/cases/${c.id}`}>CS-{c.case_no}</a> : "—"}</td>
                  <td className="num" dir="ltr">{q.revision}</td>
                  <td>{t(locale, `qs_${q.status}` as MessageKey)}</td>
                  <td className="num" dir="ltr">{tot.get(q.id) ?? "—"} {q.currency}</td>
                </tr>);
            })}</tbody>
          </table>
        )}
      </div>
    </Shell>
  );
}
