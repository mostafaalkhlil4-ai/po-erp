import { isBackendConfigured } from "./env";
import { ROLES, isAppRole, type AppRole } from "./rbac";

// Demo mode: a read-only walkthrough of the screens with SYNTHETIC static data. It has no login, no database and
// saves nothing. It is enabled only when DEMO_MODE=1 is set explicitly AND no real backend is configured, so it can
// never sit in front of real data: configuring Supabase switches it off automatically.
export function isDemoEnabled(env: Record<string, string | undefined> = process.env): boolean {
  return env.DEMO_MODE === "1" && !isBackendConfigured(env);
}

export function isDemoPath(pathname: string): boolean {
  return pathname === "/demo" || pathname.startsWith("/demo/");
}

export { ROLES, isAppRole };
export type { AppRole };

// Synthetic names only. No real people, no manufacturer products, no prices.
export const DEMO_PATIENTS = [
  { id: "P-001", name: { ar: "مريض تجريبي ١", en: "Demo patient 1" } },
  { id: "P-002", name: { ar: "مريض تجريبي ٢", en: "Demo patient 2" } },
  { id: "P-003", name: { ar: "مريض تجريبي ٣", en: "Demo patient 3" } },
] as const;

// Statuses are the real case workflow (D-022).
export const DEMO_CASES = [
  { id: "C-001", patient: "P-001", status: "assessment", mine: { technician: false, doctor: true } },
  { id: "C-002", patient: "P-002", status: "production", mine: { technician: true, doctor: true } },
  { id: "C-003", patient: "P-003", status: "fitting", mine: { technician: true, doctor: false } },
] as const;

export type DemoSection = "patients" | "cases" | "catalog" | "inventory" | "finance" | "users";

/** Which demo sections each role sees (mirrors the intent of RBAC_MATRIX; the real enforcement is RLS). */
export const DEMO_SECTIONS: Record<AppRole, readonly DemoSection[]> = {
  admin: ["users", "patients", "cases", "catalog", "inventory", "finance"],
  management: ["patients", "cases", "catalog", "inventory", "finance"],
  technician: ["cases"],
  doctor: ["patients", "cases"],
  patient: ["patients", "cases"],
};

export function demoRows(role: AppRole) {
  const patients = role === "patient" ? DEMO_PATIENTS.slice(0, 1)
    : role === "doctor" ? DEMO_PATIENTS.filter((p) => ["P-001", "P-002"].includes(p.id)) : DEMO_PATIENTS;
  const cases = DEMO_CASES.filter((c) =>
    role === "technician" ? c.mine.technician : role === "doctor" ? c.mine.doctor : role === "patient" ? c.patient === "P-001" : true);
  return { patients, cases };
}
