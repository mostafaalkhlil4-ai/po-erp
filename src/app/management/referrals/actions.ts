"use server";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { formObject } from "@/lib/form";
import { referralSchema, referralStatusSchema } from "@/lib/schemas";

export type RefState = { error?: "invalid" | "forbidden" | "failed"; ok?: boolean } | undefined;
export async function createReferral(_p: RefState, form: FormData): Promise<RefState> {
  const r = referralSchema.safeParse(formObject(form, ["patient_id", "referring_doctor_id", "reason"]));
  if (!r.success) return { error: "invalid" };
  const { error } = await (await createClient()).from("referrals").insert(r.data);
  if (error) return { error: error.code === "42501" ? "forbidden" : "failed" };
  revalidatePath("/management/referrals"); return { ok: true };
}
export async function setReferralStatus(form: FormData): Promise<void> {
  const r = referralStatusSchema.safeParse(formObject(form, ["id", "status"]));
  if (!r.success) return;
  const { error } = await (await createClient()).from("referrals").update({ status: r.data.status }).eq("id", r.data.id);
  if (error) console.error("setReferralStatus", error.code);
  revalidatePath("/management/referrals");
}
