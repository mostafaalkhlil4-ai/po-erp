"use server";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { doctorSchema } from "@/lib/schemas";
import { formObject } from "@/lib/form";

export type DoctorFormState = { error?: "invalid" | "forbidden" | "failed"; ok?: boolean } | undefined;

export async function createDoctor(_p: DoctorFormState, form: FormData): Promise<DoctorFormState> {
  const parsed = doctorSchema.safeParse(formObject(form, ["full_name", "specialty", "license_no", "phone"]));
  if (!parsed.success) return { error: "invalid" };
  const supabase = await createClient();
  const { data: ok } = await supabase.rpc("has_permission", { p_code: "doctors.manage" });
  if (ok !== true) return { error: "forbidden" };
  const { error } = await supabase.from("doctors").insert(parsed.data);
  if (error) return { error: error.code === "42501" ? "forbidden" : "failed" };
  revalidatePath("/management/doctors");
  return { ok: true };
}
