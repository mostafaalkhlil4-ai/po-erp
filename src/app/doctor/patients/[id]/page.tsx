import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getLocale } from "@/lib/locale";
import { t } from "@/lib/i18n";
import { Shell } from "@/components/Shell";
import { addRecord, addNote, addAssessment, addPrescription, cancelPrescription, addReport, setReportStatus } from "./actions";

const fmt = (d: string) => new Date(d).toISOString().slice(0, 16).replace("T", " ");

export default async function DoctorPatient({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const locale = await getLocale();
  const L = (k: Parameters<typeof t>[1]) => t(locale, k);
  const supabase = await createClient();
  const { data: p } = await supabase.from("patients").select("id,file_no,full_name,date_of_birth").eq("id", id).maybeSingle();
  if (!p) notFound(); // not linked (or no such patient): indistinguishable by design
  const [rec, notes, ass, rx, reps, canWrite] = await Promise.all([
    supabase.from("medical_records").select("id,record_type,summary,details,created_at").eq("patient_id", id).order("created_at", { ascending: false }),
    supabase.from("clinical_notes").select("id,body,created_at").eq("patient_id", id).order("created_at", { ascending: false }),
    supabase.from("assessments").select("id,findings,created_at").eq("patient_id", id).order("created_at", { ascending: false }),
    supabase.from("prescriptions").select("id,device_type,details,status,created_at").eq("patient_id", id).order("created_at", { ascending: false }),
    supabase.from("shareable_reports").select("id,title,body,status,created_at").eq("patient_id", id).order("created_at", { ascending: false }),
    supabase.rpc("has_permission", { p_code: "clinical.write" }),
  ]);
  const w = canWrite.data === true;
  const hid = <input type="hidden" name="patient_id" value={id} />;

  return (
    <Shell locale={locale} role="doctor">
      <div className="card"><h1>{p.full_name} <small>#{p.file_no}</small></h1></div>

      <section className="card" style={{ marginTop: "1rem" }}>
        <h2>{L("medicalRecords")}</h2>
        <ul>{(rec.data ?? []).map((r) => <li key={r.id}><strong>{r.record_type}</strong>: {r.summary}<br /><small>{fmt(r.created_at)}</small></li>)}</ul>
        {w && <form action={addRecord}>{hid}
          <label htmlFor="rt">{L("recordType")}</label>
          <select id="rt" name="record_type"><option value="history">history</option><option value="diagnosis">diagnosis</option><option value="allergy">allergy</option><option value="other">other</option></select>
          <label htmlFor="rs">{L("summary")}</label><input id="rs" name="summary" required maxLength={500} />
          <label htmlFor="rd">{L("details")}</label><textarea id="rd" name="details" rows={3} style={{ width: "100%" }} />
          <p><button type="submit">{L("save")}</button></p></form>}
      </section>

      <section className="card" style={{ marginTop: "1rem" }}>
        <h2>{L("clinicalNotes")}</h2>
        <ul>{(notes.data ?? []).map((n) => <li key={n.id}>{n.body}<br /><small>{fmt(n.created_at)}</small></li>)}</ul>
        {w && <form action={addNote}>{hid}<label htmlFor="nb">{L("clinicalNotes")}</label>
          <textarea id="nb" name="body" rows={3} required style={{ width: "100%" }} /><p><button type="submit">{L("save")}</button></p></form>}
      </section>

      <section className="card" style={{ marginTop: "1rem" }}>
        <h2>{L("assessments")}</h2>
        <ul>{(ass.data ?? []).map((a) => <li key={a.id}>{a.findings}<br /><small>{fmt(a.created_at)}</small></li>)}</ul>
        {w && <form action={addAssessment}>{hid}<label htmlFor="af">{L("findings")}</label>
          <textarea id="af" name="findings" rows={3} required style={{ width: "100%" }} /><p><button type="submit">{L("save")}</button></p></form>}
      </section>

      <section className="card" style={{ marginTop: "1rem" }}>
        <h2>{L("prescriptions")}</h2>
        <ul>{(rx.data ?? []).map((r) => <li key={r.id}>{r.device_type} — {r.status} <small>{fmt(r.created_at)}</small>{" "}
          {r.status === "active" && w && <form action={cancelPrescription} style={{ display: "inline" }}>
            <input type="hidden" name="id" value={r.id} />{hid}<button className="link" type="submit">{L("cancel")}</button></form>}</li>)}</ul>
        {w && <form action={addPrescription}>{hid}
          <label htmlFor="dt">{L("deviceType")}</label><input id="dt" name="device_type" required maxLength={300} />
          <label htmlFor="pd">{L("details")}</label><textarea id="pd" name="details" rows={3} style={{ width: "100%" }} />
          <p><button type="submit">{L("save")}</button></p></form>}
      </section>

      <section className="card" style={{ marginTop: "1rem" }}>
        <h2>{L("shareableReports")}</h2>
        <ul>{(reps.data ?? []).map((r) => <li key={r.id}><strong>{r.title}</strong> — {r.status}{" "}
          {w && r.status === "draft" && <form action={setReportStatus} style={{ display: "inline" }}>
            <input type="hidden" name="id" value={r.id} />{hid}<input type="hidden" name="status" value="published" />
            <button className="link" type="submit">{L("publish")}</button></form>}
          {w && r.status === "published" && <form action={setReportStatus} style={{ display: "inline" }}>
            <input type="hidden" name="id" value={r.id} />{hid}<input type="hidden" name="status" value="withdrawn" />
            <button className="link" type="submit">{L("withdraw")}</button></form>}</li>)}</ul>
        {w && <form action={addReport}>{hid}
          <label htmlFor="rt2">{L("title")}</label><input id="rt2" name="title" required maxLength={300} />
          <label htmlFor="rb">{L("body")}</label><textarea id="rb" name="body" rows={4} required style={{ width: "100%" }} />
          <p><button type="submit">{L("saveDraft")}</button></p></form>}
      </section>
    </Shell>
  );
}
