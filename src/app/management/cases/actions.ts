"use server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { formObject } from "@/lib/form";
import { caseSchema, advanceSchema, assignSchema, unassignSchema } from "@/lib/schemas";

export type CaseFormState = { error?: "invalid" | "forbidden" | "failed" } | undefined;

export async function createCase(_p: CaseFormState, form: FormData): Promise<CaseFormState> {
  const r = caseSchema.safeParse(formObject(form, ["patient_id", "case_type", "priority", "responsible_doctor_id"]));
  if (!r.success) return { error: "invalid" };
  const supabase = await createClient();
  const { data, error } = await supabase.from("cases").insert(r.data).select("id").single();
  if (error) return { error: error.code === "42501" ? "forbidden" : "failed" };
  redirect(`/management/cases/${data.id}`);
}

// Status changes go ONLY through the advance_case() database function.
export async function advanceCase(form: FormData): Promise<void> {
  const r = advanceSchema.safeParse({ case_id: form.get("case_id"), to: form.get("to"), note: form.get("note") ?? "" });
  if (!r.success) return;
  const supabase = await createClient();
  const { error } = await supabase.rpc("advance_case", { p_case: r.data.case_id, p_to: r.data.to, p_note: r.data.note });
  if (error) console.error("advance_case failed", error.code);
  revalidatePath(`/management/cases/${r.data.case_id}`);
}

export async function assignTechnician(form: FormData): Promise<void> {
  const r = assignSchema.safeParse(formObject(form, ["case_id", "technician_id"]));
  if (!r.success) return;
  const supabase = await createClient();
  const { error } = await supabase.from("case_assignments").insert(r.data);
  if (error && error.code !== "23505") console.error("assign failed", error.code);
  revalidatePath(`/management/cases/${r.data.case_id}`);
}

export async function unassignTechnician(form: FormData): Promise<void> {
  const r = unassignSchema.safeParse(formObject(form, ["id", "case_id"]));
  if (!r.success) return;
  const supabase = await createClient();
  const { error } = await supabase.from("case_assignments").update({ ended_at: new Date().toISOString() }).eq("id", r.data.id).is("ended_at", null);
  if (error) console.error("unassign failed", error.code);
  revalidatePath(`/management/cases/${r.data.case_id}`);
}
