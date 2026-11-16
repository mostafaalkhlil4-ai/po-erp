"use server";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { formObject } from "@/lib/form";
import {
  medicalRecordSchema, noteSchema, assessmentSchema, prescriptionSchema,
  reportSchema, reportStatusSchema, cancelRxSchema,
} from "@/lib/schemas";

// Each action: zod-validate -> insert/update. Authorization is enforced by RLS
// (linked doctor / admin only); a denied write returns an error code, never data.
async function run(patientId: string, op: (s: Awaited<ReturnType<typeof createClient>>) => PromiseLike<{ error: { code?: string } | null }>) {
  const supabase = await createClient();
  const { error } = await op(supabase);
  if (error) console.error("clinical action failed", error.code);
  revalidatePath(`/doctor/patients/${patientId}`);
}

export async function addRecord(form: FormData) {
  const r = medicalRecordSchema.safeParse(formObject(form, ["patient_id", "record_type", "summary", "details"]));
  if (r.success) await run(r.data.patient_id, (s) => s.from("medical_records").insert(r.data));
}
export async function addNote(form: FormData) {
  const r = noteSchema.safeParse(formObject(form, ["patient_id", "body"]));
  if (r.success) await run(r.data.patient_id, (s) => s.from("clinical_notes").insert(r.data));
}
export async function addAssessment(form: FormData) {
  const r = assessmentSchema.safeParse(formObject(form, ["patient_id", "findings"]));
  if (r.success) await run(r.data.patient_id, (s) => s.from("assessments").insert({ ...r.data, assessment_type: "clinical" }));
}
export async function addPrescription(form: FormData) {
  const r = prescriptionSchema.safeParse(formObject(form, ["patient_id", "device_type", "details"]));
  if (!r.success) return;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return;
  // The doctor id always comes from the caller's own doctor row, never from the form.
  const { data: doc } = await supabase.from("doctors").select("id").eq("user_id", user.id).maybeSingle();
  if (!doc) return;
  await run(r.data.patient_id, (s) => s.from("prescriptions").insert({ ...r.data, doctor_id: doc.id }));
}
export async function cancelPrescription(form: FormData) {
  const r = cancelRxSchema.safeParse(formObject(form, ["id", "patient_id"]));
  if (r.success) await run(r.data.patient_id, (s) => s.from("prescriptions").update({ status: "cancelled" }).eq("id", r.data.id));
}
export async function addReport(form: FormData) {
  const r = reportSchema.safeParse(formObject(form, ["patient_id", "title", "body"]));
  if (r.success) await run(r.data.patient_id, (s) => s.from("shareable_reports").insert(r.data));
}
export async function setReportStatus(form: FormData) {
  const r = reportStatusSchema.safeParse(formObject(form, ["id", "patient_id", "status"]));
  if (r.success) await run(r.data.patient_id, (s) => s.from("shareable_reports").update({ status: r.data.status }).eq("id", r.data.id));
}
