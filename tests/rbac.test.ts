import { describe, expect, it } from "vitest";
import { ROLES, canAccessPath, isAppRole, isPublicPath } from "@/lib/rbac";
import { messages, dirOf, isLocale } from "@/lib/i18n";
import { loginSchema } from "@/lib/schemas";

describe("rbac routes", () => {
  it("only admin opens /admin", () => {
    expect(ROLES.filter((r) => canAccessPath(r, "/admin"))).toEqual(["admin"]);
    expect(ROLES.filter((r) => canAccessPath(r, "/admin/users"))).toEqual(["admin"]);
  });
  it("technician/doctor/patient cannot open management area", () => {
    for (const r of ["technician", "doctor", "patient"] as const) expect(canAccessPath(r, "/management/finance")).toBe(false);
  });
  it("patient cannot open doctor or technician areas", () => {
    expect(canAccessPath("patient", "/doctor")).toBe(false);
    expect(canAccessPath("patient", "/technician/cases")).toBe(false);
  });
  it("every role opens /dashboard", () => { for (const r of ROLES) expect(canAccessPath(r, "/dashboard")).toBe(true); });
  it("unknown protected paths are denied by default", () => {
    for (const r of ROLES) expect(canAccessPath(r, "/secret")).toBe(false);
  });
  it("prefix lookalikes do not match (/administrator)", () => {
    expect(canAccessPath("management", "/administrator")).toBe(false);
    expect(canAccessPath("admin", "/administrator")).toBe(false);
  });
  it("role guard and public paths", () => {
    expect(isAppRole("admin")).toBe(true);
    expect(isAppRole("root")).toBe(false);
    expect(isPublicPath("/login")).toBe(true);
    expect(isPublicPath("/dashboard")).toBe(false);
  });
});

describe("i18n", () => {
  it("ar and en have identical keys", () => {
    expect(Object.keys(messages.ar).sort()).toEqual(Object.keys(messages.en).sort());
  });
  it("no empty strings", () => {
    for (const l of ["ar", "en"] as const) for (const v of Object.values(messages[l])) expect(v.trim()).not.toBe("");
  });
  it("directions", () => { expect(dirOf("ar")).toBe("rtl"); expect(dirOf("en")).toBe("ltr"); expect(isLocale("fr")).toBe(false); });
});

describe("login schema", () => {
  it("normalizes email", () => {
    expect(loginSchema.parse({ email: "  A@B.com ", password: "12345678" }).email).toBe("a@b.com");
  });
  it("rejects bad input", () => {
    expect(loginSchema.safeParse({ email: "nope", password: "12345678" }).success).toBe(false);
    expect(loginSchema.safeParse({ email: "a@b.com", password: "short" }).success).toBe(false);
    expect(loginSchema.safeParse({ email: "a@b.com", password: "x".repeat(129) }).success).toBe(false);
  });
});

import { updateUserSchema, resetRequestSchema, newPasswordSchema } from "@/lib/schemas";
describe("admin/user schemas and new routes", () => {
  const id = "3f2b8c1e-5d4a-4e6b-9a7c-1d2e3f4a5b6c";
  it("accepts valid role update", () => {
    expect(updateUserSchema.parse({ id, role: "doctor", is_active: "true" }).is_active).toBe(true);
  });
  it("rejects unknown role / bad id / bad status", () => {
    expect(updateUserSchema.safeParse({ id, role: "root", is_active: "true" }).success).toBe(false);
    expect(updateUserSchema.safeParse({ id: "x", role: "doctor", is_active: "true" }).success).toBe(false);
    expect(updateUserSchema.safeParse({ id, role: "doctor", is_active: "yes" }).success).toBe(false);
  });
  it("reset schemas validate", () => {
    expect(resetRequestSchema.safeParse({ email: "bad" }).success).toBe(false);
    expect(newPasswordSchema.safeParse({ password: "short" }).success).toBe(false);
    expect(newPasswordSchema.safeParse({ password: "longenough1" }).success).toBe(true);
  });
  it("/admin/users is admin-only; /reset open to all roles", () => {
    expect(ROLES.filter((r) => canAccessPath(r, "/admin/users"))).toEqual(["admin"]);
    for (const r of ROLES) expect(canAccessPath(r, "/reset")).toBe(true);
  });
});

import { patientSchema, doctorSchema, linkSchema } from "@/lib/schemas";
describe("patient/doctor schemas", () => {
  const base = { full_name: "Test Person", date_of_birth: "1990-01-01", sex: "male", phone: "0100000001", email: "", address: "" };
  it("accepts valid patient and nulls empty optionals", () => {
    const r = patientSchema.parse(base);
    expect(r.email).toBeNull(); expect(r.address).toBeNull(); expect(r.sex).toBe("male");
  });
  it("accepts minimal patient (name only)", () => {
    const r = patientSchema.parse({ full_name: "Ab", date_of_birth: "", sex: "", phone: "", email: "", address: "" });
    expect(r.date_of_birth).toBeNull(); expect(r.phone).toBeNull();
  });
  it("rejects bad patients", () => {
    expect(patientSchema.safeParse({ ...base, full_name: "A" }).success).toBe(false);
    expect(patientSchema.safeParse({ ...base, date_of_birth: "2999-01-01" }).success).toBe(false);
    expect(patientSchema.safeParse({ ...base, date_of_birth: "01/01/1990" }).success).toBe(false);
    expect(patientSchema.safeParse({ ...base, sex: "x" }).success).toBe(false);
    expect(patientSchema.safeParse({ ...base, email: "nope" }).success).toBe(false);
    expect(patientSchema.safeParse({ ...base, phone: "123" }).success).toBe(false);
  });
  it("doctor and link schemas", () => {
    expect(doctorSchema.safeParse({ full_name: "Dr X", specialty: "", license_no: "", phone: "" }).success).toBe(true);
    expect(doctorSchema.safeParse({ full_name: "", specialty: "", license_no: "", phone: "" }).success).toBe(false);
    const u = "3f2b8c1e-5d4a-4e6b-9a7c-1d2e3f4a5b6c";
    expect(linkSchema.safeParse({ patient_id: u, doctor_id: u }).success).toBe(true);
    expect(linkSchema.safeParse({ patient_id: "x", doctor_id: u }).success).toBe(false);
  });
  it("management area reachable by admin+management only", () => {
    expect(ROLES.filter((r) => canAccessPath(r, "/management/patients/abc"))).toEqual(["admin", "management"]);
  });
});

import { medicalRecordSchema, noteSchema, prescriptionSchema, reportSchema, reportStatusSchema } from "@/lib/schemas";
describe("clinical schemas and routes", () => {
  const u = "3f2b8c1e-5d4a-4e6b-9a7c-1d2e3f4a5b6c";
  it("record: valid / invalid type", () => {
    expect(medicalRecordSchema.parse({ patient_id: u, record_type: "diagnosis", summary: "x", details: "" }).details).toBeNull();
    expect(medicalRecordSchema.safeParse({ patient_id: u, record_type: "gossip", summary: "x", details: "" }).success).toBe(false);
    expect(medicalRecordSchema.safeParse({ patient_id: u, record_type: "history", summary: "  ", details: "" }).success).toBe(false);
  });
  it("note/prescription/report require content", () => {
    expect(noteSchema.safeParse({ patient_id: u, body: "" }).success).toBe(false);
    expect(prescriptionSchema.safeParse({ patient_id: u, device_type: "", details: "" }).success).toBe(false);
    expect(reportSchema.safeParse({ patient_id: u, title: "T", body: "B" }).success).toBe(true);
  });
  it("report status can only be published or withdrawn (never draft/other)", () => {
    expect(reportStatusSchema.safeParse({ id: u, patient_id: u, status: "published" }).success).toBe(true);
    expect(reportStatusSchema.safeParse({ id: u, patient_id: u, status: "draft" }).success).toBe(false);
  });
  it("route access: /doctor doctor+admin, /patient patient+admin", () => {
    expect(ROLES.filter((r) => canAccessPath(r, "/doctor/patients/x"))).toEqual(["admin", "doctor"]);
    expect(ROLES.filter((r) => canAccessPath(r, "/patient"))).toEqual(["admin", "patient"]);
  });
});

import { linkAccountSchema } from "@/lib/schemas";
describe("portal link schema", () => {
  const u = "3f2b8c1e-5d4a-4e6b-9a7c-1d2e3f4a5b6c";
  it("accepts a uuid, or empty to unlink", () => {
    expect(linkAccountSchema.parse({ id: u, user_id: u }).user_id).toBe(u);
    expect(linkAccountSchema.parse({ id: u, user_id: "" }).user_id).toBeNull();
  });
  it("rejects non-uuid", () => { expect(linkAccountSchema.safeParse({ id: u, user_id: "abc" }).success).toBe(false); });
});

import { caseSchema, advanceSchema, measurementSchema, assignSchema } from "@/lib/schemas";
describe("case schemas and routes", () => {
  const u = "3f2b8c1e-5d4a-4e6b-9a7c-1d2e3f4a5b6c";
  it("case: valid, optional doctor, bad type", () => {
    expect(caseSchema.parse({ patient_id: u, case_type: "orthotic", priority: "high", responsible_doctor_id: "" }).responsible_doctor_id).toBeNull();
    expect(caseSchema.safeParse({ patient_id: u, case_type: "magic", priority: "high", responsible_doctor_id: "" }).success).toBe(false);
    expect(caseSchema.safeParse({ patient_id: u, case_type: "orthotic", priority: "asap", responsible_doctor_id: "" }).success).toBe(false);
  });
  it("advance only accepts known statuses", () => {
    expect(advanceSchema.safeParse({ case_id: u, to: "production", note: "" }).success).toBe(true);
    expect(advanceSchema.safeParse({ case_id: u, to: "teleport", note: "" }).success).toBe(false);
  });
  it("measurement coerces numbers and rejects bad unit/value", () => {
    expect(measurementSchema.parse({ case_id: u, label: "L", value: "52.5", unit: "cm", side: "" }).value).toBe(52.5);
    expect(measurementSchema.safeParse({ case_id: u, label: "L", value: "abc", unit: "cm", side: "" }).success).toBe(false);
    expect(measurementSchema.safeParse({ case_id: u, label: "L", value: "1", unit: "miles", side: "" }).success).toBe(false);
    expect(assignSchema.safeParse({ case_id: u, technician_id: "x" }).success).toBe(false);
  });
  it("technician area: technician+admin; cases area: admin+management", () => {
    expect(ROLES.filter((r) => canAccessPath(r, "/technician/cases/x"))).toEqual(["admin", "technician"]);
    expect(ROLES.filter((r) => canAccessPath(r, "/management/cases"))).toEqual(["admin", "management"]);
  });
});
