// True only when a real backend is configured. Without it the app serves the public landing page and an honest
// "not configured" notice instead of failing or faking a login.
export function isBackendConfigured(env: Record<string, string | undefined> = process.env): boolean {
  const url = env.NEXT_PUBLIC_SUPABASE_URL ?? "";
  const key = env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "";
  if (!key || key === "dummy") return false;
  try { const u = new URL(url); return u.protocol === "https:" || u.hostname === "127.0.0.1" || u.hostname === "localhost"; } catch { return false; }
}

// Which required settings are missing/invalid. Names only, never values (safe to show on the public page).
export function backendProblems(env: Record<string, string | undefined> = process.env): string[] {
  const out: string[] = [];
  const key = env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "";
  if (!key || key === "dummy") out.push("NEXT_PUBLIC_SUPABASE_ANON_KEY");
  const url = env.NEXT_PUBLIC_SUPABASE_URL ?? "";
  let ok = false;
  try { const u = new URL(url); ok = u.protocol === "https:" || u.hostname === "127.0.0.1" || u.hostname === "localhost"; } catch { ok = false; }
  if (!ok) out.push("NEXT_PUBLIC_SUPABASE_URL");
  return out;
}
