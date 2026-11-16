"use client";
import { useActionState } from "react";
import { signIn } from "@/app/actions";

type Labels = { email: string; password: string; submit: string; invalidInput: string; invalidCredentials: string };

export function LoginForm({ labels }: { labels: Labels }) {
  const [state, action, pending] = useActionState(signIn, undefined);
  return (
    <form action={action} noValidate>
      <label htmlFor="email">{labels.email}</label>
      <input id="email" name="email" type="email" autoComplete="username" required dir="ltr" />
      <label htmlFor="password">{labels.password}</label>
      <input id="password" name="password" type="password" autoComplete="current-password" required minLength={8} dir="ltr" />
      {state?.error && <p role="alert" className="error">{labels[state.error]}</p>}
      <p><button type="submit" disabled={pending}>{labels.submit}</button></p>
    </form>
  );
}
