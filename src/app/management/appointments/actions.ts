"use server";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { formObject } from "@/lib/form";
import { appointmentSchema, appointmentStatusSchema } from "@/lib/schemas";

export type ApptState = { error?: "invalid" | "forbidden" | "failed"; ok?: boolean } | undefined;

export async function createAppointment(_p: ApptState, form: FormData): Promise<ApptState> {
  const r = appointmentSchema.safeParse(formObject(form, ["patient_id", "case_id", "appointment_type", "scheduled_at", "notes"]));
  if (!r.success) return { error: "invalid" };
  const supabase = await createClient();
  const { error } = await supabase.from("appointments").insert(r.data);
  if (error) return { error: error.code === "42501" ? "forbidden" : error.code === "23514" ? "invalid" : "failed" };
  revalidatePath("/management/appointments");
  return { ok: true };
}

export async function setAppointmentStatus(form: FormData): Promise<void> {
  const r = appointmentStatusSchema.safeParse(formObject(form, ["id", "status"]));
  if (!r.success) return;
  const supabase = await createClient();
  const { error } = await supabase.from("appointments").update({ status: r.data.status }).eq("id", r.data.id).eq("status", "scheduled");
  if (error) console.error("appointment status failed", error.code);
  revalidatePath("/management/appointments");
}
