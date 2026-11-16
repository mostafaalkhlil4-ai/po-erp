"use client";
import { useActionState } from "react";
import { createCase } from "./actions";
type Opt = { id: string; label: string };
export function CaseForm({ patients, doctors, l }: { patients: Opt[]; doctors: Opt[]; l: Record<string, string> }) {
  const [s, action, pending] = useActionState(createCase, undefined);
  return (
    <form action={action} noValidate>
      <label htmlFor="patient_id">{l.patient}</label>
      <select id="patient_id" name="patient_id" required>{patients.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}</select>
      <label htmlFor="case_type">{l.caseType}</label>
      <select id="case_type" name="case_type"><option value="prosthetic">{l.prosthetic}</option><option value="orthotic">{l.orthotic}</option><option value="rehabilitation">{l.rehabilitation}</option></select>
      <label htmlFor="priority">{l.priority}</label>
      <select id="priority" name="priority" defaultValue="normal"><option value="low">low</option><option value="normal">normal</option><option value="high">high</option><option value="urgent">urgent</option></select>
      <label htmlFor="responsible_doctor_id">{l.responsibleDoctor}</label>
      <select id="responsible_doctor_id" name="responsible_doctor_id"><option value="">—</option>{doctors.map((d) => <option key={d.id} value={d.id}>{d.label}</option>)}</select>
      {s?.error && <p role="alert" className="error">{l[`err_${s.error}`]}</p>}
      <p><button type="submit" disabled={pending}>{l.save}</button></p>
    </form>
  );
}
