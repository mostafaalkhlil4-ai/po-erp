// True only when a real backend is configured. Without it the app serves the public landing page and an honest
// "not configured" notice instead of failing or faking a login.
export function isBackendConfigured(env: Record<string, string | undefined> = process.env): boolean {
  const url = env.NEXT_PUBLIC_SUPABASE_URL ?? "";
  const key = env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "";
  if (!key || key === "dummy") return false;
  try { const u = new URL(url); return u.protocol === "https:" || u.hostname === "127.0.0.1" || u.hostname === "localhost"; } catch { return false; }
}
