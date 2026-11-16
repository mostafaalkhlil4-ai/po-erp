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
