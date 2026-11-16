"use client";
import { useActionState } from "react";
import { updatePassword } from "@/app/actions";
export function ResetForm({ labels }: { labels: { password: string; submit: string; error: string } }) {
  const [s, action, pending] = useActionState(updatePassword, undefined);
  return (
    <form action={action} noValidate>
      <label htmlFor="password">{labels.password}</label>
      <input id="password" name="password" type="password" autoComplete="new-password" required minLength={8} dir="ltr" />
      {s?.error && <p role="alert" className="error">{labels.error}</p>}
      <p><button type="submit" disabled={pending}>{labels.submit}</button></p>
    </form>
  );
}
