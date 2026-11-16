"use server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { patientSchema, linkSchema, endLinkSchema } from "@/lib/schemas";
import { formObject } from "@/lib/form";

export type PatientFormState = { error?: "invalid" | "forbidden" | "duplicate" | "failed" } | undefined;

export async function createPatient(_p: PatientFormState, form: FormData): Promise<PatientFormState> {
  const parsed = patientSchema.safeParse(
    formObject(form, ["full_name", "date_of_birth", "sex", "phone", "email", "address"]),
  );
  if (!parsed.success) return { error: "invalid" };
  const supabase = await createClient();
  const { data: ok } = await supabase.rpc("has_permission", { p_code: "patients.write" });
  if (ok !== true) return { error: "forbidden" };
  const { data, error } = await supabase.from("patients").insert(parsed.data).select("id").single();
  if (error) return { error: error.code === "23505" ? "duplicate" : error.code === "42501" ? "forbidden" : "failed" };
  redirect(`/management/patients/${data.id}`);
}

export async function linkDoctor(form: FormData): Promise<void> {
  const parsed = linkSchema.safeParse(formObject(form, ["patient_id", "doctor_id"]));
  if (!parsed.success) return;
  const supabase = await createClient();
  const { error } = await supabase.from("doctor_patient_relationships").insert(parsed.data);
  if (error && error.code !== "23505") console.error("linkDoctor", error.code);
  revalidatePath(`/management/patients/${parsed.data.patient_id}`);
}

export async function endLink(form: FormData): Promise<void> {
  const parsed = endLinkSchema.safeParse(formObject(form, ["id", "patient_id"]));
  if (!parsed.success) return;
  const supabase = await createClient();
  const { error } = await supabase
    .from("doctor_patient_relationships").update({ ended_at: new Date().toISOString() })
    .eq("id", parsed.data.id).is("ended_at", null);
  if (error) console.error("endLink", error.code);
  revalidatePath(`/management/patients/${parsed.data.patient_id}`);
}
