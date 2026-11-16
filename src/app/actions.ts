"use server";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { LOCALE_COOKIE, isLocale } from "@/lib/i18n";
import { loginSchema } from "@/lib/schemas";

export async function signIn(_prev: { error?: "invalidInput" | "invalidCredentials" } | undefined, form: FormData) {
  const parsed = loginSchema.safeParse({ email: form.get("email"), password: form.get("password") });
  if (!parsed.success) return { error: "invalidInput" as const };
  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword(parsed.data);
  // Same message for every failure: do not reveal whether the account exists.
  if (error) return { error: "invalidCredentials" as const };
  redirect("/dashboard");
}

export async function signOut() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/login");
}

export async function setLocale(form: FormData) {
  const v = form.get("locale");
  if (isLocale(v)) (await cookies()).set(LOCALE_COOKIE, v, { path: "/", maxAge: 31536000, sameSite: "lax" });
}

import { headers } from "next/headers";
import { newPasswordSchema, resetRequestSchema } from "@/lib/schemas";

export async function requestReset(_p: { sent?: boolean; error?: "invalidInput" } | undefined, form: FormData) {
  const parsed = resetRequestSchema.safeParse({ email: form.get("email") });
  if (!parsed.success) return { error: "invalidInput" as const };
  const origin = process.env.NEXT_PUBLIC_SITE_URL ?? (await headers()).get("origin") ?? "";
  const supabase = await createClient();
  await supabase.auth.resetPasswordForEmail(parsed.data.email, {
    redirectTo: `${origin}/auth/callback?next=/reset`,
  });
  // Always the same answer: never reveal whether the email is registered.
  return { sent: true };
}

export async function updatePassword(_p: { error?: "invalidInput" | "failed" } | undefined, form: FormData) {
  const parsed = newPasswordSchema.safeParse({ password: form.get("password") });
  if (!parsed.success) return { error: "invalidInput" as const };
  const supabase = await createClient();
  const { error } = await supabase.auth.updateUser({ password: parsed.data.password });
  if (error) return { error: "failed" as const };
  redirect("/dashboard");
}
