import { z } from "zod";
export const loginSchema = z.object({
  email: z.string().trim().toLowerCase().email().max(254),
  password: z.string().min(8).max(128),
});

import { ROLES } from "./rbac";
export const updateUserSchema = z.object({
  id: z.string().uuid(),
  role: z.enum(ROLES),
  is_active: z.enum(["true", "false"]).transform((v) => v === "true"),
});
export const resetRequestSchema = z.object({ email: z.string().trim().toLowerCase().email().max(254) });
export const newPasswordSchema = z.object({ password: z.string().min(8).max(128) });

const optionalText = (max: number) =>
  z.string().trim().max(max).transform((v) => (v === "" ? null : v)).nullable();
export const patientSchema = z.object({
  full_name: z.string().trim().min(2).max(200),
  date_of_birth: z
    .string().trim()
    .regex(/^\d{4}-\d{2}-\d{2}$/)
    .refine((d) => !Number.isNaN(Date.parse(d)) && d <= new Date().toISOString().slice(0, 10))
    .or(z.literal("").transform(() => null)),
  sex: z.enum(["male", "female", ""]).transform((v) => (v === "" ? null : v)),
  phone: z.string().trim().min(5).max(30).or(z.literal("").transform(() => null)),
  email: z.string().trim().toLowerCase().email().max(254).or(z.literal("").transform(() => null)),
  address: optionalText(500),
});
export const doctorSchema = z.object({
  full_name: z.string().trim().min(2).max(200),
  specialty: optionalText(200),
  license_no: optionalText(100),
  phone: z.string().trim().min(5).max(30).or(z.literal("").transform(() => null)),
});
export const linkSchema = z.object({ patient_id: z.string().uuid(), doctor_id: z.string().uuid() });
export const endLinkSchema = z.object({ id: z.string().uuid(), patient_id: z.string().uuid() });

const uuid = z.string().uuid();
export const medicalRecordSchema = z.object({
  patient_id: uuid,
  record_type: z.enum(["history", "diagnosis", "allergy", "other"]),
  summary: z.string().trim().min(1).max(500),
  details: optionalText(5000),
});
export const noteSchema = z.object({ patient_id: uuid, body: z.string().trim().min(1).max(10000) });
export const assessmentSchema = z.object({ patient_id: uuid, findings: z.string().trim().min(1).max(10000) });
export const prescriptionSchema = z.object({
  patient_id: uuid,
  device_type: z.string().trim().min(1).max(300),
  details: optionalText(5000),
});
export const reportSchema = z.object({
  patient_id: uuid,
  title: z.string().trim().min(1).max(300),
  body: z.string().trim().min(1).max(20000),
});
export const reportStatusSchema = z.object({
  id: uuid,
  patient_id: uuid,
  status: z.enum(["published", "withdrawn"]),
});
export const cancelRxSchema = z.object({ id: uuid, patient_id: uuid });

export const linkAccountSchema = z.object({
  id: z.string().uuid(),                       // patient or doctor id
  user_id: z.string().uuid().or(z.literal("").transform(() => null)),
});

export const CASE_STATUSES = ["assessment","product_selection","quotation","approved","production","quality_control","fitting","delivered","follow_up","closed","cancelled"] as const;
export const caseSchema = z.object({
  patient_id: z.string().uuid(),
  case_type: z.enum(["prosthetic", "orthotic", "rehabilitation"]),
  priority: z.enum(["low", "normal", "high", "urgent"]),
  responsible_doctor_id: z.string().uuid().or(z.literal("").transform(() => null)),
});
export const advanceSchema = z.object({
  case_id: z.string().uuid(),
  to: z.enum(CASE_STATUSES),
  note: optionalText(1000),
});
export const assignSchema = z.object({ case_id: z.string().uuid(), technician_id: z.string().uuid() });
export const unassignSchema = z.object({ id: z.string().uuid(), case_id: z.string().uuid() });
export const measurementSchema = z.object({
  case_id: z.string().uuid(),
  label: z.string().trim().min(1).max(100),
  value: z.coerce.number().finite().min(-100000).max(100000),
  unit: z.enum(["mm", "cm", "kg", "deg"]),
  side: z.enum(["left", "right", ""]).transform((v) => (v === "" ? null : v)),
});
export const techAssessmentSchema = z.object({
  case_id: z.string().uuid(), patient_id: z.string().uuid(), findings: z.string().trim().min(1).max(10000),
});

export const appointmentSchema = z.object({
  patient_id: z.string().uuid(),
  case_id: z.string().uuid().or(z.literal("").transform(() => null)),
  appointment_type: z.enum(["assessment", "fitting", "follow_up", "consultation", "other"]),
  scheduled_at: z.string().trim().refine((v) => !Number.isNaN(Date.parse(v))).transform((v) => new Date(v).toISOString()),
  notes: optionalText(1000),
});
export const appointmentStatusSchema = z.object({
  id: z.string().uuid(),
  status: z.enum(["completed", "cancelled", "no_show"]),
});

const currency = z.string().trim().toUpperCase().regex(/^[A-Z]{3}$/);
const money = z.coerce.number().finite().min(0).max(999999999999);
export const productSchema = z.object({
  manufacturer_id: z.string().uuid(),
  category_id: z.string().uuid().or(z.literal("").transform(() => null)),
  name: z.string().trim().min(1).max(300),
  sku: z.string().trim().min(1).max(100),
  description: optionalText(2000),
});
export const categorySchema = z.object({ name: z.string().trim().min(1).max(200) });
export const priceSchema = z.object({ product_id: z.string().uuid(), price: money, currency });
export const quotationSchema = z.object({
  case_id: z.string().uuid(), currency,
  tax_rate: z.coerce.number().min(0).max(100),
});
export const quotationItemSchema = z.object({
  quotation_id: z.string().uuid(),
  item_type: z.enum(["product", "material", "service"]),
  product_id: z.string().uuid().or(z.literal("").transform(() => null)),
  description: z.string().trim().max(500),
  quantity: z.coerce.number().gt(0).max(100000),
  unit_price: z.union([money, z.literal("").transform(() => null)]),
}).superRefine((v, ctx) => {
  if (v.item_type === "product" && !v.product_id) ctx.addIssue({ code: "custom", path: ["product_id"], message: "required" });
  if (v.item_type !== "product" && (v.unit_price === null || v.description === "")) ctx.addIssue({ code: "custom", path: ["unit_price"], message: "required" });
});
export const quotationIdSchema = z.object({ id: z.string().uuid() });
export const discountSchema = z.object({ id: z.string().uuid(), discount_percent: z.coerce.number().min(0).max(100) });
export const rejectSchema = z.object({ id: z.string().uuid(), reason: z.string().trim().min(1).max(1000) });
export const removeItemSchema = z.object({ id: z.string().uuid(), quotation_id: z.string().uuid() });

export const stageSchema = z.object({ case_id: z.string().uuid(), name: z.string().trim().min(1).max(100), position: z.coerce.number().int().min(0).max(1000) });
export const stageStatusSchema = z.object({ id: z.string().uuid(), case_id: z.string().uuid(), to: z.enum(["in_progress", "completed"]), notes: z.string().trim().max(2000).transform((v) => (v === "" ? null : v)) });
export const qcSchema = z.object({ case_id: z.string().uuid(), result: z.enum(["pass", "fail"]), notes: z.string().trim().max(2000).transform((v) => (v === "" ? null : v)) })
  .refine((v) => v.result === "pass" || v.notes !== null, { path: ["notes"], message: "required" });

export const paymentSchema = z.object({
  invoice_id: z.string().uuid(), amount: z.coerce.number().gt(0).max(999999999999),
  method: z.enum(["cash", "bank_transfer", "card", "other"]),
  reference: z.string().trim().max(200).transform((v) => (v === "" ? null : v)),
});
export const expenseSchema = z.object({
  category: z.string().trim().min(1).max(100), description: z.string().trim().max(1000).transform((v) => (v === "" ? null : v)),
  amount: z.coerce.number().gt(0).max(999999999999), currency: z.string().trim().toUpperCase().regex(/^[A-Z]{3}$/),
  incurred_on: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
});
export const voidInvoiceSchema = z.object({ id: z.string().uuid(), reason: z.string().trim().min(1).max(1000) });

export const deviceSchema = z.object({
  case_id: z.string().uuid(), device_type: z.string().trim().min(1).max(200),
  side: z.enum(["left", "right", "both", ""]).transform((v) => (v === "" ? null : v)),
  description: z.string().trim().max(2000).transform((v) => (v === "" ? null : v)),
});
export const componentSchema = z.object({ device_id: z.string().uuid(), case_id: z.string().uuid(), name: z.string().trim().min(1).max(200), notes: z.string().trim().max(1000).transform((v) => (v === "" ? null : v)) });
export const followUpSchema = z.object({ case_id: z.string().uuid(), due_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/) });
export const followUpUpdateSchema = z.object({
  id: z.string().uuid(), case_id: z.string().uuid(), status: z.enum(["planned", "done", "cancelled"]),
  technical_feedback: z.string().trim().max(5000).transform((v) => (v === "" ? null : v)),
  device_issues: z.string().trim().max(5000).transform((v) => (v === "" ? null : v)),
});
export const ATTACHMENT_MIME: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "application/pdf": "pdf" };
export const MAX_ATTACHMENT_BYTES = 26214400;
export const attachmentMetaSchema = z.object({
  patient_id: z.string().uuid(), case_id: z.string().uuid().or(z.literal("").transform(() => null)),
  category: z.enum(["photo", "document", "design", "report", "other"]), visibility: z.enum(["internal", "shared"]),
});
export function checkAttachmentFile(f: { type: string; size: number; name: string }): boolean {
  return f.type in ATTACHMENT_MIME && f.size > 0 && f.size <= MAX_ATTACHMENT_BYTES && f.name.length > 0 && f.name.length <= 255;
}

export const referralSchema = z.object({ patient_id: z.string().uuid(), referring_doctor_id: z.string().uuid(), reason: z.string().trim().max(2000).transform((v) => (v === "" ? null : v)) });
export const referralStatusSchema = z.object({ id: z.string().uuid(), status: z.enum(["received", "accepted", "rejected", "closed"]) });

const qty = z.coerce.number().gt(0).max(10000000);
export const itemSchema = z.object({ name: z.string().trim().min(1).max(200), sku: z.string().trim().min(1).max(100), unit: z.string().trim().min(1).max(30), min_stock: z.coerce.number().min(0).max(10000000) });
export const movementSchema = z.object({
  item_id: z.string().uuid(), kind: z.enum(["receipt", "issue", "adjust_in", "adjust_out"]), quantity: qty,
  case_id: z.string().uuid().or(z.literal("").transform(() => null)), notes: z.string().trim().max(1000).transform((v) => (v === "" ? null : v)),
}).superRefine((v, ctx) => {
  if (v.kind === "issue" && !v.case_id) ctx.addIssue({ code: "custom", path: ["case_id"], message: "required" });
  if ((v.kind === "adjust_in" || v.kind === "adjust_out") && !v.notes) ctx.addIssue({ code: "custom", path: ["notes"], message: "required" });
});
export const supplierSchema = z.object({ name: z.string().trim().min(1).max(200), contact: z.string().trim().max(500).transform((v) => (v === "" ? null : v)) });
export const poSchema = z.object({ supplier_id: z.string().uuid(), currency: z.string().trim().toUpperCase().regex(/^[A-Z]{3}$/) });
export const poItemSchema = z.object({ po_id: z.string().uuid(), item_id: z.string().uuid(), quantity: qty, unit_cost: z.coerce.number().min(0).max(999999999999) });
export const poStatusSchema = z.object({ id: z.string().uuid(), to: z.enum(["ordered", "received", "cancelled"]) });
