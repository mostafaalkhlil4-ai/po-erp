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

import { appointmentSchema, appointmentStatusSchema } from "@/lib/schemas";
describe("appointment schemas", () => {
  const u = "3f2b8c1e-5d4a-4e6b-9a7c-1d2e3f4a5b6c";
  it("normalizes datetime to ISO, optional case/notes", () => {
    const r = appointmentSchema.parse({ patient_id: u, case_id: "", appointment_type: "fitting", scheduled_at: "2026-12-01T10:30", notes: "" });
    expect(r.case_id).toBeNull(); expect(r.notes).toBeNull(); expect(r.scheduled_at).toMatch(/^2026-12-01T/);
  });
  it("rejects bad date/type; status cannot go back to scheduled", () => {
    expect(appointmentSchema.safeParse({ patient_id: u, case_id: "", appointment_type: "fitting", scheduled_at: "soon", notes: "" }).success).toBe(false);
    expect(appointmentSchema.safeParse({ patient_id: u, case_id: "", appointment_type: "party", scheduled_at: "2026-12-01T10:30", notes: "" }).success).toBe(false);
    expect(appointmentStatusSchema.safeParse({ id: u, status: "scheduled" }).success).toBe(false);
    expect(appointmentStatusSchema.safeParse({ id: u, status: "completed" }).success).toBe(true);
  });
});

import { productSchema, priceSchema, quotationSchema, quotationItemSchema, discountSchema } from "@/lib/schemas";
describe("catalog and quotation schemas", () => {
  const u = "3f2b8c1e-5d4a-4e6b-9a7c-1d2e3f4a5b6c";
  it("price: normalizes currency, rejects bad values", () => {
    expect(priceSchema.parse({ product_id: u, price: "10.5", currency: " usd " }).currency).toBe("USD");
    expect(priceSchema.safeParse({ product_id: u, price: "-1", currency: "USD" }).success).toBe(false);
    expect(priceSchema.safeParse({ product_id: u, price: "1", currency: "US" }).success).toBe(false);
    expect(priceSchema.safeParse({ product_id: u, price: "abc", currency: "USD" }).success).toBe(false);
  });
  it("product requires manufacturer, name and sku", () => {
    expect(productSchema.safeParse({ manufacturer_id: u, category_id: "", name: "X", sku: "S", description: "" }).success).toBe(true);
    expect(productSchema.safeParse({ manufacturer_id: u, category_id: "", name: "X", sku: " ", description: "" }).success).toBe(false);
  });
  it("quotation: tax in 0..100; no default currency", () => {
    expect(quotationSchema.safeParse({ case_id: u, currency: "EUR", tax_rate: "15" }).success).toBe(true);
    expect(quotationSchema.safeParse({ case_id: u, currency: "EUR", tax_rate: "101" }).success).toBe(false);
    expect(quotationSchema.safeParse({ case_id: u, currency: "", tax_rate: "5" }).success).toBe(false);
  });
  it("items: product needs product id; service needs description and price", () => {
    expect(quotationItemSchema.safeParse({ quotation_id: u, item_type: "product", product_id: u, description: "", quantity: "1", unit_price: "" }).success).toBe(true);
    expect(quotationItemSchema.safeParse({ quotation_id: u, item_type: "product", product_id: "", description: "", quantity: "1", unit_price: "" }).success).toBe(false);
    expect(quotationItemSchema.safeParse({ quotation_id: u, item_type: "service", product_id: "", description: "Fee", quantity: "1", unit_price: "5" }).success).toBe(true);
    expect(quotationItemSchema.safeParse({ quotation_id: u, item_type: "service", product_id: "", description: "", quantity: "1", unit_price: "5" }).success).toBe(false);
    expect(quotationItemSchema.safeParse({ quotation_id: u, item_type: "material", product_id: "", description: "M", quantity: "0", unit_price: "5" }).success).toBe(false);
  });
  it("discount in 0..100", () => {
    expect(discountSchema.safeParse({ id: u, discount_percent: "10" }).success).toBe(true);
    expect(discountSchema.safeParse({ id: u, discount_percent: "120" }).success).toBe(false);
  });
});

import { stageSchema, stageStatusSchema, qcSchema } from "@/lib/schemas";
describe("production schemas", () => {
  const u = "3f2b8c1e-5d4a-4e6b-9a7c-1d2e3f4a5b6c";
  it("stage needs a name; position is a non-negative integer", () => {
    expect(stageSchema.safeParse({ case_id: u, name: "Casting", position: "1" }).success).toBe(true);
    expect(stageSchema.safeParse({ case_id: u, name: " ", position: "1" }).success).toBe(false);
    expect(stageSchema.safeParse({ case_id: u, name: "X", position: "-1" }).success).toBe(false);
  });
  it("stage status only allows forward moves", () => {
    expect(stageStatusSchema.safeParse({ id: u, case_id: u, to: "completed", notes: "" }).success).toBe(true);
    expect(stageStatusSchema.safeParse({ id: u, case_id: u, to: "pending", notes: "" }).success).toBe(false);
  });
  it("failed QC requires notes", () => {
    expect(qcSchema.safeParse({ case_id: u, result: "pass", notes: "" }).success).toBe(true);
    expect(qcSchema.safeParse({ case_id: u, result: "fail", notes: "" }).success).toBe(false);
    expect(qcSchema.safeParse({ case_id: u, result: "fail", notes: "misaligned" }).success).toBe(true);
  });
});

import { paymentSchema, expenseSchema, voidInvoiceSchema } from "@/lib/schemas";
describe("finance schemas", () => {
  const u = "3f2b8c1e-5d4a-4e6b-9a7c-1d2e3f4a5b6c";
  it("payment: positive amount, known method", () => {
    expect(paymentSchema.safeParse({ invoice_id: u, amount: "10", method: "cash", reference: "" }).success).toBe(true);
    expect(paymentSchema.safeParse({ invoice_id: u, amount: "0", method: "cash", reference: "" }).success).toBe(false);
    expect(paymentSchema.safeParse({ invoice_id: u, amount: "5", method: "barter", reference: "" }).success).toBe(false);
  });
  it("expense: ISO currency, valid date, positive amount", () => {
    expect(expenseSchema.safeParse({ category: "Materials", description: "", amount: "5", currency: "usd", incurred_on: "2026-11-01" }).success).toBe(true);
    expect(expenseSchema.safeParse({ category: "Materials", description: "", amount: "5", currency: "US", incurred_on: "2026-11-01" }).success).toBe(false);
    expect(expenseSchema.safeParse({ category: "M", description: "", amount: "5", currency: "USD", incurred_on: "01/11/2026" }).success).toBe(false);
  });
  it("void needs a reason", () => {
    expect(voidInvoiceSchema.safeParse({ id: u, reason: " " }).success).toBe(false);
    expect(voidInvoiceSchema.safeParse({ id: u, reason: "mistake" }).success).toBe(true);
  });
});

import { deviceSchema, followUpSchema, attachmentMetaSchema, checkAttachmentFile } from "@/lib/schemas";
describe("device, follow-up and attachment rules", () => {
  const u = "3f2b8c1e-5d4a-4e6b-9a7c-1d2e3f4a5b6c";
  it("device needs a type; side is optional", () => {
    expect(deviceSchema.safeParse({ case_id: u, device_type: "Knee", side: "", description: "" }).success).toBe(true);
    expect(deviceSchema.safeParse({ case_id: u, device_type: "", side: "", description: "" }).success).toBe(false);
    expect(deviceSchema.safeParse({ case_id: u, device_type: "x", side: "up", description: "" }).success).toBe(false);
  });
  it("follow-up date format", () => {
    expect(followUpSchema.safeParse({ case_id: u, due_date: "2026-12-01" }).success).toBe(true);
    expect(followUpSchema.safeParse({ case_id: u, due_date: "tomorrow" }).success).toBe(false);
  });
  it("attachment file allowlist and size", () => {
    expect(checkAttachmentFile({ type: "application/pdf", size: 1000, name: "a.pdf" })).toBe(true);
    expect(checkAttachmentFile({ type: "image/svg+xml", size: 1000, name: "a.svg" })).toBe(false);
    expect(checkAttachmentFile({ type: "image/png", size: 26214401, name: "a.png" })).toBe(false);
    expect(checkAttachmentFile({ type: "image/png", size: 0, name: "a.png" })).toBe(false);
    expect(attachmentMetaSchema.safeParse({ patient_id: u, case_id: "", category: "photo", visibility: "internal" }).success).toBe(true);
    expect(attachmentMetaSchema.safeParse({ patient_id: u, case_id: "", category: "exe", visibility: "internal" }).success).toBe(false);
  });
});

import { itemSchema, movementSchema, poSchema, poItemSchema } from "@/lib/schemas";
describe("inventory and procurement schemas", () => {
  const u = "3f2b8c1e-5d4a-4e6b-9a7c-1d2e3f4a5b6c";
  it("issue needs a case; adjustments need notes", () => {
    expect(movementSchema.safeParse({ item_id: u, kind: "issue", quantity: "2", case_id: u, notes: "" }).success).toBe(true);
    expect(movementSchema.safeParse({ item_id: u, kind: "issue", quantity: "2", case_id: "", notes: "" }).success).toBe(false);
    expect(movementSchema.safeParse({ item_id: u, kind: "adjust_out", quantity: "1", case_id: "", notes: "" }).success).toBe(false);
    expect(movementSchema.safeParse({ item_id: u, kind: "adjust_out", quantity: "1", case_id: "", notes: "count" }).success).toBe(true);
    expect(movementSchema.safeParse({ item_id: u, kind: "receipt", quantity: "0", case_id: "", notes: "" }).success).toBe(false);
  });
  it("item and purchase order validation", () => {
    expect(itemSchema.safeParse({ name: "A", sku: "S", unit: "pc", min_stock: "0" }).success).toBe(true);
    expect(itemSchema.safeParse({ name: "A", sku: "", unit: "pc", min_stock: "0" }).success).toBe(false);
    expect(poSchema.safeParse({ supplier_id: u, currency: "eur" }).success).toBe(true);
    expect(poSchema.safeParse({ supplier_id: u, currency: "EU" }).success).toBe(false);
    expect(poItemSchema.safeParse({ po_id: u, item_id: u, quantity: "1", unit_cost: "-1" }).success).toBe(false);
  });
});

import { visibilitySchema } from "@/lib/schemas";
describe("patient visibility schema", () => {
  const u = "3f2b8c1e-5d4a-4e6b-9a7c-1d2e3f4a5b6c";
  it("kind and flag are strict", () => {
    expect(visibilitySchema.parse({ kind: "invoice", id: u, visible: "true" }).visible).toBe(true);
    expect(visibilitySchema.parse({ kind: "quotation", id: u, visible: "false" }).visible).toBe(false);
    expect(visibilitySchema.safeParse({ kind: "payment", id: u, visible: "true" }).success).toBe(false);
    expect(visibilitySchema.safeParse({ kind: "invoice", id: u, visible: "yes" }).success).toBe(false);
  });
});

import { orgSettingsSchema } from "@/lib/schemas";
describe("orgSettingsSchema", () => {
  it("accepts empty optional fields as null and trims", () => {
    expect(orgSettingsSchema.parse({ center_name: "  Demo  ", phone: "", email: "", address: "" }))
      .toEqual({ center_name: "Demo", phone: null, email: null, address: null });
  });
  it("rejects bad e-mail and over-long values", () => {
    expect(orgSettingsSchema.safeParse({ center_name: "", phone: "", email: "nope", address: "" }).success).toBe(false);
    expect(orgSettingsSchema.safeParse({ center_name: "x".repeat(201), phone: "", email: "", address: "" }).success).toBe(false);
  });
});
