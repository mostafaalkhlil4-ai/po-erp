"use client";
import { useActionState } from "react";
import { createPatient } from "./actions";

type L = Record<string, string>;
export function PatientForm({ l }: { l: L }) {
  const [s, action, pending] = useActionState(createPatient, undefined);
  const f = (id: string, label: string, type = "text", extra: object = {}) => (
    <div><label htmlFor={id}>{label}</label><input id={id} name={id} type={type} {...extra} /></div>
  );
  return (
    <form action={action} noValidate>
      {f("full_name", l.fullName, "text", { required: true, minLength: 2, maxLength: 200 })}
      {f("date_of_birth", l.dob, "date", { dir: "ltr" })}
      <label htmlFor="sex">{l.sex}</label>
      <select id="sex" name="sex" defaultValue="">
        <option value="">—</option><option value="male">{l.male}</option><option value="female">{l.female}</option>
      </select>
      {f("phone", l.phone, "tel", { dir: "ltr" })}
      {f("email", l.email, "email", { dir: "ltr" })}
      {f("address", l.address)}
      {s?.error && <p role="alert" className="error">{l[`err_${s.error}`]}</p>}
      <p><button type="submit" disabled={pending}>{l.save}</button></p>
    </form>
  );
}
