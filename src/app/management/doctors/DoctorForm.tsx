"use client";
import { useActionState } from "react";
import { createDoctor } from "./actions";
type L = Record<string, string>;
export function DoctorForm({ l }: { l: L }) {
  const [s, action, pending] = useActionState(createDoctor, undefined);
  return (
    <form action={action} noValidate key={s?.ok ? "done" : "form"}>
      <label htmlFor="full_name">{l.fullName}</label><input id="full_name" name="full_name" required minLength={2} />
      <label htmlFor="specialty">{l.specialty}</label><input id="specialty" name="specialty" />
      <label htmlFor="license_no">{l.licenseNo}</label><input id="license_no" name="license_no" dir="ltr" />
      <label htmlFor="phone">{l.phone}</label><input id="phone" name="phone" type="tel" dir="ltr" />
      {s?.error && <p role="alert" className="error">{l[`err_${s.error}`]}</p>}
      {s?.ok && <p role="status">{l.saved}</p>}
      <p><button type="submit" disabled={pending}>{l.save}</button></p>
    </form>
  );
}
