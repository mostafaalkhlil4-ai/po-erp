"use client";
import { useActionState } from "react";
import { requestReset } from "@/app/actions";
export function ForgotForm({ labels }: { labels: { email: string; submit: string; sent: string; invalid: string } }) {
  const [s, action, pending] = useActionState(requestReset, undefined);
  return (
    <form action={action} noValidate>
      <label htmlFor="email">{labels.email}</label>
      <input id="email" name="email" type="email" autoComplete="email" required dir="ltr" />
      {s?.error && <p role="alert" className="error">{labels.invalid}</p>}
      {s?.sent && <p role="status">{labels.sent}</p>}
      <p><button type="submit" disabled={pending}>{labels.submit}</button></p>
    </form>
  );
}
