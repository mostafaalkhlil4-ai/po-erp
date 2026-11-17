"use client";
import { useActionState } from "react";
import { createAppointment } from "./actions";
type Opt = { id: string; label: string; patient_id?: string };
export function ApptForm({ patients, cases, l }: { patients: Opt[]; cases: Opt[]; l: Record<string, string> }) {
  const [s, action, pending] = useActionState(createAppointment, undefined);
  return (
    <form action={action} noValidate>
      <label htmlFor="patient_id">{l.patient}</label>
      <select id="patient_id" name="patient_id" required>{patients.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}</select>
      <label htmlFor="case_id">{l.case}</label>
      <select id="case_id" name="case_id"><option value="">—</option>{cases.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}</select>
      <label htmlFor="appointment_type">{l.type}</label>
      <select id="appointment_type" name="appointment_type">
        {["assessment", "fitting", "follow_up", "consultation", "other"].map((x) => <option key={x} value={x}>{l[`ap_${x}`]}</option>)}
      </select>
      <label htmlFor="scheduled_at">{l.when}</label>
      <input id="scheduled_at" name="scheduled_at" type="datetime-local" required dir="ltr" />
      <label htmlFor="notes">{l.notes}</label><input id="notes" name="notes" maxLength={1000} />
      {s?.error && <p role="alert" className="error">{l[`err_${s.error}`]}</p>}
      {s?.ok && <p role="status">{l.saved}</p>}
      <p><button type="submit" disabled={pending}>{l.save}</button></p>
    </form>
  );
}
