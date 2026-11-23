import { describe, it, expect } from "vitest";
import { isDemoEnabled, isDemoPath, demoRows, DEMO_SECTIONS } from "@/lib/demo";
const real = { NEXT_PUBLIC_SUPABASE_URL: "https://a.supabase.co", NEXT_PUBLIC_SUPABASE_ANON_KEY: "k" };
describe("demo mode", () => {
  it("is off unless explicitly enabled", () => { expect(isDemoEnabled({})).toBe(false); expect(isDemoEnabled({ DEMO_MODE: "0" })).toBe(false); });
  it("is on only with the flag and no backend", () => { expect(isDemoEnabled({ DEMO_MODE: "1" })).toBe(true); });
  it("is switched off whenever a real backend is configured", () => { expect(isDemoEnabled({ DEMO_MODE: "1", ...real })).toBe(false); });
  it("only matches demo paths", () => { expect(isDemoPath("/demo")).toBe(true); expect(isDemoPath("/demo/admin")).toBe(true); expect(isDemoPath("/demonstration")).toBe(false); expect(isDemoPath("/admin")).toBe(false); });
  it("scopes rows per role and never exposes finance to technician/doctor/patient", () => {
    expect(demoRows("patient").patients).toHaveLength(1);
    expect(demoRows("technician").cases.every((c) => c.mine.technician)).toBe(true);
    for (const r of ["technician", "doctor", "patient"] as const) expect(DEMO_SECTIONS[r]).not.toContain("finance");
  });
});
