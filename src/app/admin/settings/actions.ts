"use server";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { formObject } from "@/lib/form";
import { orgSettingsSchema } from "@/lib/schemas";

export type SettingsState = { error?: "invalid" | "forbidden" | "failed"; ok?: boolean } | undefined;

export async function saveSettings(_p: SettingsState, form: FormData): Promise<SettingsState> {
  const r = orgSettingsSchema.safeParse(formObject(form, ["center_name", "phone", "email", "address"]));
  if (!r.success) return { error: "invalid" };
  const { error } = await (await createClient()).from("org_settings").upsert({ id: true, ...r.data });
  if (error) return { error: error.code === "42501" ? "forbidden" : "failed" };
  revalidatePath("/admin/settings");
  return { ok: true };
}
