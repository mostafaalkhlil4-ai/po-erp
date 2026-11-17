"use server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { formObject } from "@/lib/form";
import { quotationSchema, quotationItemSchema, quotationIdSchema, discountSchema, rejectSchema, removeItemSchema } from "@/lib/schemas";

export type QState = { error?: "invalid" | "forbidden" | "failed" | "noPrice" } | undefined;

export async function createQuotation(_p: QState, form: FormData): Promise<QState> {
  const r = quotationSchema.safeParse(formObject(form, ["case_id", "currency", "tax_rate"]));
  if (!r.success) return { error: "invalid" };
  const { data, error } = await (await createClient()).from("quotations").insert(r.data).select("id").single();
  if (error) return { error: error.code === "42501" ? "forbidden" : "failed" };
  redirect(`/management/quotations/${data.id}`);
}

export async function addItem(_p: QState, form: FormData): Promise<QState> {
  const r = quotationItemSchema.safeParse(formObject(form, ["quotation_id", "item_type", "product_id", "description", "quantity", "unit_price"]));
  if (!r.success) return { error: "invalid" };
  // For product items the price is fetched by the database; any submitted price is not sent.
  const row: Record<string, unknown> = r.data.item_type === "product"
    ? { quotation_id: r.data.quotation_id, item_type: "product", product_id: r.data.product_id, description: "-", quantity: r.data.quantity, unit_price: 0 }
    : { ...r.data, product_id: null };
  const { error } = await (await createClient()).from("quotation_items").insert(row);
  if (error) return { error: error.code === "42501" ? "forbidden" : error.message.includes("base price") ? "noPrice" : error.code === "23514" ? "invalid" : "failed" };
  revalidatePath(`/management/quotations/${r.data.quotation_id}`);
  return undefined;
}

export async function removeItem(form: FormData): Promise<void> {
  const r = removeItemSchema.safeParse(formObject(form, ["id", "quotation_id"]));
  if (!r.success) return;
  const { error } = await (await createClient()).from("quotation_items").delete().eq("id", r.data.id);
  if (error) console.error("removeItem", error.code);
  revalidatePath(`/management/quotations/${r.data.quotation_id}`);
}

export async function setDiscount(form: FormData): Promise<void> {
  const r = discountSchema.safeParse(formObject(form, ["id", "discount_percent"]));
  if (!r.success) return;
  const { error } = await (await createClient()).from("quotations").update({ discount_percent: r.data.discount_percent }).eq("id", r.data.id);
  if (error) console.error("setDiscount", error.code);
  revalidatePath(`/management/quotations/${r.data.id}`);
}

// All status changes go through the database functions (permission + state checks + snapshot).
async function call(fn: "submit_quotation" | "approve_quotation", form: FormData) {
  const r = quotationIdSchema.safeParse(formObject(form, ["id"]));
  if (!r.success) return;
  const { error } = await (await createClient()).rpc(fn, { p_q: r.data.id });
  if (error) console.error(fn, error.code);
  revalidatePath(`/management/quotations/${r.data.id}`);
}
export async function submitQuotation(form: FormData): Promise<void> { await call("submit_quotation", form); }
export async function approveQuotation(form: FormData): Promise<void> { await call("approve_quotation", form); }
export async function rejectQuotation(form: FormData): Promise<void> {
  const r = rejectSchema.safeParse(formObject(form, ["id", "reason"]));
  if (!r.success) return;
  const { error } = await (await createClient()).rpc("reject_quotation", { p_q: r.data.id, p_reason: r.data.reason });
  if (error) console.error("reject", error.code);
  revalidatePath(`/management/quotations/${r.data.id}`);
}
export async function reviseQuotation(form: FormData): Promise<void> {
  const r = quotationIdSchema.safeParse(formObject(form, ["id"]));
  if (!r.success) return;
  const { data, error } = await (await createClient()).rpc("revise_quotation", { p_q: r.data.id });
  if (error || !data) { console.error("revise", error?.code); return; }
  redirect(`/management/quotations/${data}`);
}
