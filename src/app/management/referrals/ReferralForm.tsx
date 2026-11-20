"use client";
import { useActionState } from "react";
import { createReferral } from "./actions";
type Opt = { id: string; label: string };
export function ReferralForm({ patients, doctors, l }: { patients: Opt[]; doctors: Opt[]; l: Record<string, string> }) {
  const [s, a, p] = useActionState(createReferral, undefined);
  return (<form action={a} noValidate key={s?.ok ? "ok" : "f"}>
    <label htmlFor="patient_id">{l.patient}</label>
    <select id="patient_id" name="patient_id" required>{patients.map((x) => <option key={x.id} value={x.id}>{x.label}</option>)}</select>
    <label htmlFor="referring_doctor_id">{l.doctor}</label>
    <select id="referring_doctor_id" name="referring_doctor_id" required>{doctors.map((x) => <option key={x.id} value={x.id}>{x.label}</option>)}</select>
    <label htmlFor="reason">{l.reason}</label><input id="reason" name="reason" maxLength={2000} />
    {s?.error && <p role="alert" className="error">{l[`err_${s.error}`]}</p>}{s?.ok && <p role="status">{l.saved}</p>}
    <p><button type="submit" disabled={p}>{l.save}</button></p></form>);
}
