"use server";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { formObject } from "@/lib/form";
import { stageSchema, stageStatusSchema, qcSchema } from "@/lib/schemas";

function refresh(caseId: string) {
  revalidatePath(`/technician/cases/${caseId}`);
  revalidatePath(`/management/cases/${caseId}`);
}
// Authorization is enforced by RLS and the database functions; failures are logged server-side.
export async function addStage(form: FormData): Promise<void> {
  const r = stageSchema.safeParse(formObject(form, ["case_id", "name", "position"]));
  if (!r.success) return;
  const { error } = await (await createClient()).from("production_stages").insert(r.data);
  if (error) console.error("addStage", error.code);
  refresh(r.data.case_id);
}
export async function setStage(form: FormData): Promise<void> {
  const r = stageStatusSchema.safeParse(formObject(form, ["id", "case_id", "to", "notes"]));
  if (!r.success) return;
  const { error } = await (await createClient()).rpc("set_stage_status", { p_stage: r.data.id, p_to: r.data.to, p_notes: r.data.notes });
  if (error) console.error("setStage", error.code);
  refresh(r.data.case_id);
}
export async function addQualityCheck(form: FormData): Promise<void> {
  const r = qcSchema.safeParse(formObject(form, ["case_id", "result", "notes"]));
  if (!r.success) return;
  const { error } = await (await createClient()).from("quality_checks").insert(r.data);
  if (error) console.error("addQualityCheck", error.code);
  refresh(r.data.case_id);
}
