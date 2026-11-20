"use server";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { formObject } from "@/lib/form";
import { itemSchema, movementSchema } from "@/lib/schemas";

export type InvState = { error?: "invalid" | "forbidden" | "duplicate" | "stock" | "failed"; ok?: boolean } | undefined;
const map = (c?: string): InvState => ({ error: c === "42501" ? "forbidden" : c === "23505" ? "duplicate" : c === "23514" ? "stock" : "failed" });
function refresh(caseId?: string | null) { revalidatePath("/management/inventory"); if (caseId) revalidatePath(`/technician/cases/${caseId}`); }

export async function createItem(_p: InvState, form: FormData): Promise<InvState> {
  const r = itemSchema.safeParse(formObject(form, ["name", "sku", "unit", "min_stock"]));
  if (!r.success) return { error: "invalid" };
  const { error } = await (await createClient()).from("inventory_items").insert(r.data);
  if (error) return map(error.code);
  refresh(); return { ok: true };
}
export async function addMovement(_p: InvState, form: FormData): Promise<InvState> {
  const r = movementSchema.safeParse(formObject(form, ["item_id", "kind", "quantity", "case_id", "notes"]));
  if (!r.success) return { error: "invalid" };
  const { error } = await (await createClient()).from("stock_movements").insert(r.data);
  if (error) return map(error.code);
  refresh(r.data.case_id); return { ok: true };
}
