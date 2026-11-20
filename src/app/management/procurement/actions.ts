"use server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { formObject } from "@/lib/form";
import { supplierSchema, poSchema, poItemSchema, poStatusSchema, quotationIdSchema } from "@/lib/schemas";

export type ProcState = { error?: "invalid" | "forbidden" | "duplicate" | "failed"; ok?: boolean } | undefined;
const map = (c?: string): ProcState => ({ error: c === "42501" ? "forbidden" : c === "23505" ? "duplicate" : c === "23514" ? "invalid" : "failed" });

export async function createSupplier(_p: ProcState, form: FormData): Promise<ProcState> {
  const r = supplierSchema.safeParse(formObject(form, ["name", "contact"]));
  if (!r.success) return { error: "invalid" };
  const { error } = await (await createClient()).from("suppliers").insert(r.data);
  if (error) return map(error.code);
  revalidatePath("/management/procurement"); return { ok: true };
}
export async function createPO(_p: ProcState, form: FormData): Promise<ProcState> {
  const r = poSchema.safeParse(formObject(form, ["supplier_id", "currency"]));
  if (!r.success) return { error: "invalid" };
  const { data, error } = await (await createClient()).from("purchase_orders").insert(r.data).select("id").single();
  if (error) return map(error.code);
  redirect(`/management/procurement/${data.id}`);
}
export async function addPOItem(_p: ProcState, form: FormData): Promise<ProcState> {
  const r = poItemSchema.safeParse(formObject(form, ["po_id", "item_id", "quantity", "unit_cost"]));
  if (!r.success) return { error: "invalid" };
  const { error } = await (await createClient()).from("purchase_order_items").insert(r.data);
  if (error) return map(error.code);
  revalidatePath(`/management/procurement/${r.data.po_id}`); return { ok: true };
}
export async function removePOItem(form: FormData): Promise<void> {
  const id = quotationIdSchema.safeParse(formObject(form, ["id"]));
  const po = quotationIdSchema.safeParse({ id: form.get("po_id") });
  if (!id.success || !po.success) return;
  const { error } = await (await createClient()).from("purchase_order_items").delete().eq("id", id.data.id);
  if (error) console.error("removePOItem", error.code);
  revalidatePath(`/management/procurement/${po.data.id}`);
}
export async function setPOStatus(form: FormData): Promise<void> {
  const r = poStatusSchema.safeParse(formObject(form, ["id", "to"]));
  if (!r.success) return;
  const { error } = await (await createClient()).rpc("po_set_status", { p_po: r.data.id, p_to: r.data.to });
  if (error) console.error("setPOStatus", error.code);
  revalidatePath(`/management/procurement/${r.data.id}`); revalidatePath("/management/procurement"); revalidatePath("/management/inventory");
}
