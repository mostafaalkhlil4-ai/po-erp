"use server";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { formObject } from "@/lib/form";
import { measurementSchema, techAssessmentSchema, advanceSchema } from "@/lib/schemas";

export async function addMeasurement(form: FormData): Promise<void> {
  const r = measurementSchema.safeParse(formObject(form, ["case_id", "label", "value", "unit", "side"]));
  if (!r.success) return;
  const supabase = await createClient();
  const { error } = await supabase.from("measurements").insert(r.data);
  if (error) console.error("measurement failed", error.code);
  revalidatePath(`/technician/cases/${r.data.case_id}`);
}
export async function addTechAssessment(form: FormData): Promise<void> {
  const r = techAssessmentSchema.safeParse(formObject(form, ["case_id", "patient_id", "findings"]));
  if (!r.success) return;
  const supabase = await createClient();
  const { error } = await supabase.from("assessments").insert({ ...r.data, assessment_type: "technical" });
  if (error) console.error("tech assessment failed", error.code);
  revalidatePath(`/technician/cases/${r.data.case_id}`);
}
export async function techAdvance(form: FormData): Promise<void> {
  const r = advanceSchema.safeParse({ case_id: form.get("case_id"), to: form.get("to"), note: form.get("note") ?? "" });
  if (!r.success) return;
  const supabase = await createClient();
  const { error } = await supabase.rpc("advance_case", { p_case: r.data.case_id, p_to: r.data.to, p_note: r.data.note });
  if (error) console.error("advance failed", error.code);
  revalidatePath(`/technician/cases/${r.data.case_id}`);
}
