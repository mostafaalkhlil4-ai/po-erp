"use server";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { updateUserSchema } from "@/lib/schemas";

export type UpdateResult = { ok: true } | { ok: false; error: "invalid" | "forbidden" | "lastAdmin" | "failed" };

export async function updateUser(form: FormData): Promise<void> {
  const parsed = updateUserSchema.safeParse({
    id: form.get("id"), role: form.get("role"), is_active: form.get("is_active"),
  });
  if (!parsed.success) return;
  const supabase = await createClient();
  // Server-side permission check; RLS + profiles_guard trigger enforce it again in the DB.
  const { data: allowed } = await supabase.rpc("has_permission", { p_code: "users.manage" });
  if (allowed !== true) return;
  const { error } = await supabase
    .from("profiles").update({ role: parsed.data.role, is_active: parsed.data.is_active })
    .eq("id", parsed.data.id);
  if (error) console.error("updateUser failed", error.code);
  revalidatePath("/admin/users");
}
