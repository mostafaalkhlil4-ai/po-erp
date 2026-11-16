import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";
import { linkDoctor, endLink } from "../actions";
import { linkPatientAccount } from "../../accounts";

export default async function PatientDetail({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const locale = await getLocale();
  const supabase = await createClient();
  const { data: p } = await supabase.from("patients")
    .select("id,file_no,full_name,date_of_birth,sex,phone,email,address,user_id").eq("id", id).maybeSingle();
  if (!p) notFound();
  const [{ data: links }, { data: doctors }, { data: canLink }] = await Promise.all([
    supabase.from("doctor_patient_relationships").select("id,doctor_id,started_at").eq("patient_id", id).is("ended_at", null),
    supabase.from("doctors").select("id,full_name,specialty").eq("is_active", true).order("full_name"),
    supabase.rpc("has_permission", { p_code: "doctors.manage" }),
  ]);
  const canWrite = (await supabase.rpc("has_permission", { p_code: "patients.write" })).data === true;
  const [{ data: accounts }, { data: taken }] = canWrite
    ? await Promise.all([
        supabase.from("profiles").select("id,email,full_name").eq("role", "patient").eq("is_active", true).order("email"),
        supabase.from("patients").select("user_id").not("user_id", "is", null),
      ])
    : [{ data: [] }, { data: [] }];
  const takenIds = new Set((taken ?? []).map((x) => x.user_id));
  const free = (accounts ?? []).filter((a) => !takenIds.has(a.id) || a.id === p.user_id);
  // Clinical content is read-only here and only returned if RLS allows (D-019).
  const [rec, notes, ass, rx, reps] = await Promise.all([
    supabase.from("medical_records").select("id,record_type,summary,created_at").eq("patient_id", id).order("created_at", { ascending: false }),
    supabase.from("clinical_notes").select("id,body,created_at").eq("patient_id", id).order("created_at", { ascending: false }),
    supabase.from("assessments").select("id,findings,created_at").eq("patient_id", id).order("created_at", { ascending: false }),
    supabase.from("prescriptions").select("id,device_type,status,created_at").eq("patient_id", id).order("created_at", { ascending: false }),
    supabase.from("shareable_reports").select("id,title,status").eq("patient_id", id).order("created_at", { ascending: false }),
  ]);
  const hasClinical = [rec, notes, ass, rx, reps].some((q) => (q.data ?? []).length > 0);
  const name = new Map((doctors ?? []).map((d) => [d.id, d.full_name]));
  const linkedIds = new Set((links ?? []).map((l) => l.doctor_id));

  return (
    <Shell locale={locale}>
      <div className="card">
        <h1>{p.full_name} <small>#{p.file_no}</small></h1>
        <dl>
          <dt>{t(locale, "dob")}</dt><dd dir="ltr">{p.date_of_birth ?? "—"}</dd>
          <dt>{t(locale, "sex")}</dt><dd>{p.sex ? t(locale, p.sex === "male" ? "male" : "female") : "—"}</dd>
          <dt>{t(locale, "phone")}</dt><dd dir="ltr">{p.phone ?? "—"}</dd>
          <dt>{t(locale, "email")}</dt><dd dir="ltr">{p.email ?? "—"}</dd>
          <dt>{t(locale, "address")}</dt><dd>{p.address ?? "—"}</dd>
        </dl>
      </div>
      <div className="card" style={{ marginTop: "1rem" }}>
        <h2>{t(locale, "linkedDoctors")}</h2>
        <ul>{(links ?? []).map((l) => (
          <li key={l.id}>{name.get(l.doctor_id) ?? "—"}{" "}
            {canLink === true && (
              <form action={endLink} style={{ display: "inline" }}>
                <input type="hidden" name="id" value={l.id} /><input type="hidden" name="patient_id" value={p.id} />
                <button className="link" type="submit">{t(locale, "endLink")}</button>
              </form>)}
          </li>))}
        </ul>
        {(links ?? []).length === 0 && <p>{t(locale, "noResults")}</p>}
        {canLink === true && (
          <form action={linkDoctor} style={{ display: "flex", gap: ".5rem" }}>
            <input type="hidden" name="patient_id" value={p.id} />
            <select name="doctor_id" aria-label={t(locale, "doctors")} required>
              {(doctors ?? []).filter((d) => !linkedIds.has(d.id)).map((d) => (
                <option key={d.id} value={d.id}>{d.full_name}{d.specialty ? ` — ${d.specialty}` : ""}</option>))}
            </select>
            <button type="submit">{t(locale, "linkDoctor")}</button>
          </form>)}
      </div>
      {canWrite && (
        <div className="card" style={{ marginTop: "1rem" }}>
          <h2>{t(locale, "portalAccount")}</h2>
          <form action={linkPatientAccount} style={{ display: "flex", gap: ".5rem" }}>
            <input type="hidden" name="id" value={p.id} />
            <select name="user_id" defaultValue={p.user_id ?? ""} aria-label={t(locale, "portalAccount")}>
              <option value="">—</option>
              {free.map((a) => <option key={a.id} value={a.id}>{a.email}</option>)}
            </select>
            <button type="submit">{t(locale, "save")}</button>
          </form>
        </div>)}
      {hasClinical && (
        <div className="card" style={{ marginTop: "1rem" }}>
          <h2>{t(locale, "clinicalReadOnly")}</h2>
          <h3>{t(locale, "medicalRecords")}</h3>
          <ul>{(rec.data ?? []).map((r) => <li key={r.id}><strong>{r.record_type}</strong>: {r.summary}</li>)}</ul>
          <h3>{t(locale, "clinicalNotes")}</h3>
          <ul>{(notes.data ?? []).map((n) => <li key={n.id}>{n.body}</li>)}</ul>
          <h3>{t(locale, "assessments")}</h3>
          <ul>{(ass.data ?? []).map((a) => <li key={a.id}>{a.findings}</li>)}</ul>
          <h3>{t(locale, "prescriptions")}</h3>
          <ul>{(rx.data ?? []).map((r) => <li key={r.id}>{r.device_type} — {r.status}</li>)}</ul>
          <h3>{t(locale, "shareableReports")}</h3>
          <ul>{(reps.data ?? []).map((r) => <li key={r.id}>{r.title} — {r.status}</li>)}</ul>
        </div>)}
    </Shell>
  );
}
