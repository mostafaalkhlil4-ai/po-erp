"use server";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { linkAccountSchema } from "@/lib/schemas";
import { formObject } from "@/lib/form";

// Links (or unlinks, with empty user_id) a portal account. The DB trigger
// rejects accounts whose role does not match; unique constraints reject reuse.
async function link(table: "patients" | "doctors", form: FormData, path: string) {
  const r = linkAccountSchema.safeParse(formObject(form, ["id", "user_id"]));
  if (!r.success) return;
  const supabase = await createClient();
  const { error } = await supabase.from(table).update({ user_id: r.data.user_id }).eq("id", r.data.id);
  if (error) console.error("link account failed", error.code);
  revalidatePath(path);
}
export async function linkPatientAccount(form: FormData) { await link("patients", form, "/management/patients"); }
export async function linkDoctorAccount(form: FormData) { await link("doctors", form, "/management/doctors"); }
